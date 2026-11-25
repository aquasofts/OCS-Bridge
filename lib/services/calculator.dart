import 'dart:math' as math;

String calculate(String expression) {
  if (expression.length > 256) throw const FormatException('算式过长');
  final parser = _Calculator(expression);
  final value = parser.sum();
  if (!parser.done) throw const FormatException('算式无效');
  return value == value.truncateToDouble() && value.abs() <= 9007199254740991
      ? value.toStringAsFixed(0)
      : value.toString();
}

double _finite(double value) {
  if (!value.isFinite) throw const FormatException('计算无定义或超出数值范围');
  return value;
}

class _Calculator {
  _Calculator(this.source);
  final String source;
  int index = 0;
  static final _number = RegExp(r'(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?');
  static final _name = RegExp(r'[a-z][a-z0-9]*');

  bool get done {
    while (index < source.length && ' \t\n\r'.contains(source[index])) {
      index++;
    }
    return index == source.length;
  }

  bool take(String token) {
    if (done || !source.startsWith(token, index)) return false;
    index += token.length;
    return true;
  }

  double sum() {
    var value = product();
    while (true) {
      if (take('+')) {
        value = _finite(value + product());
      } else if (take('-')) {
        value = _finite(value - product());
      } else {
        return value;
      }
    }
  }

  double product() {
    var value = unary();
    while (true) {
      if (take('*') || take('×')) {
        value = _finite(value * unary());
      } else if (take('/') || take('÷')) {
        value = _finite(value / unary());
      } else if (take('%')) {
        value = _finite(value % unary());
      } else {
        return value;
      }
    }
  }

  double unary() {
    if (take('+')) return unary();
    if (take('-')) return -unary();
    final base = atom();
    return take('^') ? _finite(math.pow(base, unary()).toDouble()) : base;
  }

  double group() {
    final value = sum();
    if (!take(')')) throw const FormatException('缺少右括号');
    return value;
  }

  double atom() {
    if (take('(')) return group();
    final number = _number.matchAsPrefix(source, index);
    if (number != null) {
      index = number.end;
      return _finite(double.parse(number.group(0)!));
    }
    final name = _name.matchAsPrefix(source, index);
    if (name == null) throw const FormatException('缺少数字或函数');
    index = name.end;
    if (name.group(0) == 'pi') return math.pi;
    if (name.group(0) == 'e') return math.e;
    if (!take('(')) throw const FormatException('函数缺少括号');
    final value = group();
    return _finite(switch (name.group(0)) {
      'sqrt' => math.sqrt(value),
      'abs' => value.abs(),
      'ln' => math.log(value),
      'log10' => math.log(value) / math.ln10,
      'sin' => math.sin(value),
      'cos' => math.cos(value),
      'tan' => math.tan(value),
      'exp' => math.exp(value),
      _ => throw const FormatException('不支持此函数'),
    });
  }
}
