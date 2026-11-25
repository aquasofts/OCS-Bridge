import 'dart:convert';
import 'dart:math';

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 30).toRadixString(36)}';
String newToken() => base64UrlEncode(
  List.generate(32, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

enum ProviderKind { openai, deepseek, compatible }

enum ApiProtocol { chat, responses }

enum SearchMode { off, auto, required }

enum CalculationMode { off, localPython, calculator, hostedPython }

class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.kind = ProviderKind.compatible,
    this.supportsResponses = true,
  });
  final String id, name, baseUrl;
  final ProviderKind kind;
  final bool supportsResponses;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'kind': kind.name,
    'supportsResponses': supportsResponses,
  };
  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
    id: j['id'] as String,
    name: j['name'] as String,
    baseUrl: j['baseUrl'] as String,
    kind: ProviderKind.values.byName(j['kind'] as String),
    supportsResponses: j['supportsResponses'] as bool? ?? true,
  );
}

class ModelConfig {
  const ModelConfig({
    required this.id,
    required this.name,
    required this.model,
    required this.providerId,
    this.protocol = ApiProtocol.responses,
    this.search = SearchMode.off,
    this.effort = 'default',
    this.thinking = 'default',
    this.maxTokens = 8192,
    this.timeoutSeconds = 120,
    this.temperature,
    this.vision = false,
    this.calculation = CalculationMode.off,
    this.extra = const {},
  });
  final String id, name, model, providerId, effort, thinking;
  final ApiProtocol protocol;
  final SearchMode search;
  final int maxTokens, timeoutSeconds;
  final double? temperature;
  final bool vision;
  final CalculationMode calculation;
  bool get python => calculation == CalculationMode.hostedPython;
  bool get usesLocalCalculation =>
      calculation == CalculationMode.localPython ||
      calculation == CalculationMode.calculator;
  final Map<String, dynamic> extra;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'model': model,
    'providerId': providerId,
    'protocol': protocol.name,
    'search': search.name,
    'effort': effort,
    'thinking': thinking,
    'maxTokens': maxTokens,
    'timeoutSeconds': timeoutSeconds,
    'temperature': temperature,
    'vision': vision,
    'calculation': calculation.name,
    'extra': extra,
  };
  factory ModelConfig.fromJson(Map<String, dynamic> j) => ModelConfig(
    id: j['id'] as String,
    name: j['name'] as String,
    model: j['model'] as String,
    providerId: j['providerId'] as String,
    protocol: ApiProtocol.values.byName(j['protocol'] as String),
    search: SearchMode.values.byName(j['search'] as String),
    effort: j['effort'] as String? ?? 'default',
    thinking: j['thinking'] as String? ?? 'default',
    maxTokens: j['maxTokens'] as int? ?? 8192,
    timeoutSeconds: j['timeoutSeconds'] as int? ?? 120,
    temperature: (j['temperature'] as num?)?.toDouble(),
    vision: j['vision'] as bool? ?? false,
    calculation: j['calculation'] is String
        ? CalculationMode.values.byName(j['calculation'] as String)
        : j['python'] == true
        ? CalculationMode.hostedPython
        : CalculationMode.off,
    extra: Map<String, dynamic>.from(j['extra'] as Map? ?? {}),
  );
}

class AppConfig {
  AppConfig({
    required List<ProviderConfig> providers,
    required List<ModelConfig> models,
    required this.token,
    this.activeModelId,
    this.port = 15318,
    this.darkMode = false,
    this.autoStart = false,
    this.cacheEnabled = true,
    this.allowGuess = true,
    this.agentMode = true,
  }) : providers = List<ProviderConfig>.of(providers),
       models = List<ModelConfig>.of(models);
  List<ProviderConfig> providers;
  List<ModelConfig> models;
  String token;
  String? activeModelId;
  int port;
  bool darkMode, autoStart, cacheEnabled, allowGuess, agentMode;
  factory AppConfig.initial() => AppConfig(
    providers: const [
      ProviderConfig(
        id: 'openai',
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        kind: ProviderKind.openai,
      ),
      ProviderConfig(
        id: 'deepseek',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        kind: ProviderKind.deepseek,
      ),
    ],
    models: const [],
    token: newToken(),
  );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'providers': providers.map((x) => x.toJson()).toList(),
    'models': models.map((x) => x.toJson()).toList(),
    'token': token,
    'activeModelId': activeModelId,
    'port': port,
    'darkMode': darkMode,
    'autoStart': autoStart,
    'cacheEnabled': cacheEnabled,
    'allowGuess': allowGuess,
    'agentMode': agentMode,
  };
  factory AppConfig.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 1) {
      throw const FormatException('配置版本不支持');
    }
    final c = AppConfig(
      providers: (j['providers'] as List)
          .map(
            (x) => ProviderConfig.fromJson(Map<String, dynamic>.from(x as Map)),
          )
          .toList(),
      models: (j['models'] as List)
          .map((x) => ModelConfig.fromJson(Map<String, dynamic>.from(x as Map)))
          .toList(),
      token: j['token'] as String,
      activeModelId: j['activeModelId'] as String?,
      port: j['port'] as int? ?? 15318,
      darkMode: j['darkMode'] as bool? ?? false,
      autoStart: j['autoStart'] as bool? ?? false,
      cacheEnabled: j['cacheEnabled'] as bool? ?? true,
      allowGuess: j['allowGuess'] as bool? ?? true,
      agentMode: j['agentMode'] as bool? ?? true,
    );
    if (c.port < 1024 ||
        c.port > 65535 ||
        c.token.length < 24 ||
        c.providers.map((p) => p.id).toSet().length != c.providers.length ||
        c.models.map((m) => m.id).toSet().length != c.models.length) {
      throw const FormatException('配置数据无效');
    }
    for (final p in c.providers) {
      validateProvider(p);
    }
    for (final m in c.models) {
      final p = c.providers.where((p) => p.id == m.providerId).firstOrNull;
      if (p == null) {
        throw const FormatException('模型供应商不存在');
      }
      validateModel(m, p);
    }
    if (c.activeModelId != null &&
        !c.models.any((m) => m.id == c.activeModelId)) {
      throw const FormatException('当前模型不存在');
    }
    return c;
  }
}

void validateProvider(ProviderConfig p) {
  final u = Uri.tryParse(p.baseUrl);
  if (p.name.trim().isEmpty ||
      u == null ||
      !u.hasAuthority ||
      !['https', 'http'].contains(u.scheme) ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment) {
    throw const FormatException('请填写有效的供应商地址');
  }
  if (u.scheme == 'http' &&
      !['localhost', '127.0.0.1', '::1'].contains(u.host)) {
    throw const FormatException('远程供应商需使用 HTTPS');
  }
}

bool supportsHostedPython(ApiProtocol protocol, ProviderConfig provider) =>
    protocol == ApiProtocol.responses &&
    provider.supportsResponses &&
    provider.kind != ProviderKind.deepseek;

bool usesDeepSeekWebTools(ModelConfig model, ProviderConfig provider) =>
    provider.kind == ProviderKind.deepseek && model.model == 'deepseek-flash';

bool supportsHostedSearch(ModelConfig model, ProviderConfig provider) {
  final responses = model.protocol == ApiProtocol.responses;
  if (responses && !provider.supportsResponses) return false;
  if (provider.kind == ProviderKind.deepseek) {
    return usesDeepSeekWebTools(model, provider) ||
        (responses && model.model == 'deepseek-v4-pro');
  }
  return responses || model.search != SearchMode.off;
}

void validateModel(ModelConfig m, ProviderConfig p) {
  if (m.name.trim().isEmpty || m.model.trim().isEmpty) {
    throw const FormatException('请填写模型名称和 ID');
  }
  if (m.protocol == ApiProtocol.responses && !p.supportsResponses) {
    throw const FormatException('供应商未启用 Responses');
  }
  if (m.python && !supportsHostedPython(m.protocol, p)) {
    throw const FormatException('Python 计算需要支持代码解释器的 Responses 接口');
  }
  if (m.maxTokens < 64 ||
      m.maxTokens > 393216 ||
      m.timeoutSeconds < 5 ||
      m.timeoutSeconds > 600) {
    throw const FormatException('请检查 Token 和超时范围');
  }
  if (m.temperature != null && (m.temperature! < 0 || m.temperature! > 2)) {
    throw const FormatException('温度范围为 0–2');
  }
  if (p.kind == ProviderKind.deepseek &&
      m.search != SearchMode.off &&
      !supportsHostedSearch(m, p)) {
    throw const FormatException(
      'DeepSeek 联网请选择 deepseek-flash 或 deepseek-v4-pro（Responses）',
    );
  }
  if (m.protocol == ApiProtocol.chat &&
      m.search == SearchMode.required &&
      !usesDeepSeekWebTools(m, p)) {
    throw const FormatException('强制搜索请使用 Responses');
  }
  const reserved = {
    'model',
    'messages',
    'input',
    'instructions',
    'stream',
    'tools',
    'tool_choice',
    'reasoning',
    'reasoning_effort',
    'thinking',
    'max_tokens',
    'max_completion_tokens',
    'max_output_tokens',
    'temperature',
    'web_search_options',
  };
  if (m.extra.keys.any(reserved.contains)) {
    throw const FormatException('扩展参数不能覆盖已有设置');
  }
  if (m.protocol == ApiProtocol.responses &&
      m.thinking != 'default' &&
      p.kind != ProviderKind.deepseek) {
    throw const FormatException('Responses 使用思考深度控制推理');
  }
  if (p.kind == ProviderKind.deepseek &&
      m.thinking == 'disabled' &&
      !['none', 'default'].contains(m.effort)) {
    throw const FormatException('关闭思考时请将深度设为默认或 none');
  }
}
