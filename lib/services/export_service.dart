import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../app_controller.dart';
import '../domain/config.dart';
import 'app_log.dart';

enum AnswerExportFormat { json, csv, txt, markdown }

extension AnswerExportLabel on AnswerExportFormat {
  String get label => switch (this) {
    AnswerExportFormat.json => 'JSON',
    AnswerExportFormat.csv => 'CSV',
    AnswerExportFormat.txt => 'TXT',
    AnswerExportFormat.markdown => 'Markdown',
  };
  String get extension => this == AnswerExportFormat.markdown ? 'md' : name;
}

String renderAnswers(
  List<RequestRecord> records,
  AnswerExportFormat format, {
  DateTime? exportedAt,
}) {
  final time = (exportedAt ?? DateTime.now()).toUtc().toIso8601String();
  if (format == AnswerExportFormat.json) {
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'exportedAt': time,
      'count': records.length,
      'records': records.map((r) => r.toJson()).toList(),
    });
  }
  if (format == AnswerExportFormat.csv) {
    String cell(Object? value) =>
        '"${(value?.toString() ?? '').replaceAll('"', '""')}"';
    final rows = <List<Object?>>[
      [
        'ID',
        '时间',
        '模型名称',
        '供应商',
        '模型 ID',
        '题型',
        '题目',
        '选项',
        '答案',
        '解析',
        '来源',
        '状态',
        '缓存',
        '耗时毫秒',
        '输入 Token',
        '输出 Token',
        '搜索次数',
        '网页读取',
        '错误',
        '错误堆栈',
        '图片',
        '模型设置',
        '供应商设置',
      ],
      for (final r in records)
        [
          r.id,
          r.time.toIso8601String(),
          r.model,
          r.providerSettings['name'],
          r.modelSettings['model'],
          r.question.type,
          r.question.title,
          r.question.options,
          r.result?.ocsAnswer,
          r.result?.explanation,
          r.result?.sources.join('\n'),
          r.error != null
              ? '失败'
              : (r.result?.answers.isEmpty ?? true)
              ? '无答案'
              : '成功',
          r.cached,
          r.duration.inMilliseconds,
          r.result?.inputTokens,
          r.result?.outputTokens,
          r.result?.searchCalls,
          r.result?.pageReads,
          r.error,
          r.errorStack,
          jsonEncode(r.question.images),
          jsonEncode(r.modelSettings),
          jsonEncode(r.providerSettings),
        ],
    ];
    return '\uFEFF${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
  }
  final markdown = format == AnswerExportFormat.markdown;
  final out = StringBuffer(markdown ? '# 答案导出\n\n' : '答案导出\n');
  out.writeln('导出时间：$time\n记录数：${records.length}\n');
  for (var i = 0; i < records.length; i++) {
    final r = records[i];
    out.writeln('${markdown ? '## ' : ''}${i + 1}. ${r.question.title}\n');
    if (r.question.options.isNotEmpty) out.writeln('${r.question.options}\n');
    out.writeln('答案：${r.result?.answers.join('；') ?? ''}');
    if (r.result?.explanation.isNotEmpty ?? false) {
      out.writeln('解析：${r.result!.explanation}');
    }
    if (r.result?.sources.isNotEmpty ?? false) {
      out.writeln('来源：${r.result!.sources.join('\n')}');
    }
    if (r.error != null) out.writeln('错误：${r.error}');
    out.writeln(
      '模型：${r.model}\n时间：${r.time.toIso8601String()}\n耗时：${r.duration.inMilliseconds} ms',
    );
    out.writeln('\n${markdown ? '---' : '────────────────────────'}\n');
  }
  return out.toString();
}

class AnswerExporter {
  AnswerExporter({this.log});
  final AppLog? log;
  static const channel = MethodChannel('dev.ocsbridge/files');
  Future<String?> save(
    List<RequestRecord> records,
    AnswerExportFormat format,
  ) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp('[-:]'), '')
        .replaceAll('T', '-');
    log?.write('runtime', 'export.choose', {
      'format': format.name,
      'records': records.map((r) => r.id).toList(),
    });
    final path = await channel.invokeMethod<String>('chooseSave', {
      'filename': 'OCS-answers-$stamp.${format.extension}',
      'extension': format.extension,
      'description': format.label,
    });
    if (path == null) {
      log?.write('runtime', 'export.cancelled', {});
      return null;
    }
    return write(path, records, format);
  }

  Future<String> write(
    String path,
    List<RequestRecord> records,
    AnswerExportFormat format,
  ) async {
    final text = renderAnswers(records, format);
    final bytes = utf8.encode(text);
    final temp = File('$path.${newId()}.tmp');
    log?.write('runtime', 'export.write.start', {
      'path': path,
      'format': format.name,
      'count': records.length,
      'body': logBytes(bytes),
    });
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(path);
      log?.write('runtime', 'export.write.complete', {
        'path': path,
        'format': format.name,
        'count': records.length,
        'bytes': bytes.length,
      });
      try {
        await log?.flush();
      } catch (error, stack) {
        log?.error('export.log.flush.error', error, stack, {'path': path});
      }
      return path;
    } catch (error, stack) {
      log?.error('export.write.error', error, stack, {'path': path});
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }
}
