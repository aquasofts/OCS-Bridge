"""Evaluate an allowlist of math expressions using exact SymPy values."""

import ast
import json
import math
import operator
import sys

import sympy as s
from sympy.core.evalf import PrecisionExhausted


MAX_EXPRESSION_LENGTH = 256
MAX_BATCH_SIZE = 8
MAX_BITS = 4096
MATH_CHARACTERS = str.maketrans({'×': '*', '÷': '/', '−': '-', 'π': 'pi', '^': '**'})
X = s.Symbol('x', real=True)


def power(base, exponent):
    if abs(exponent) > 1000 or (exponent.is_Rational and exponent.q > 1000):
        raise ValueError()
    # Rational powers with odd denominators have a real value on negative bases.
    if exponent.is_Rational and exponent.q % 2 and base.is_negative:
        return (-1)**(exponent.p % 2) * (-base)**exponent
    return base**exponent


def round_number(value, digits=s.S.Zero):
    if not digits.is_Integer or abs(digits) > 128:
        raise ValueError()
    scale = s.Integer(10)**digits
    scaled = value * scale
    lower = s.floor(scaled)
    if scaled - lower == s.S.Half:
        return (lower + lower % 2) / scale
    return s.floor(scaled + s.S.Half) / scale


def combinatorics(function, n, *args):
    n = operator.index(n)
    if not 0 <= n <= 500:
        raise ValueError()
    return s.Integer(function(n, *(operator.index(arg) for arg in args)))


BINARY = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.FloorDiv: lambda a, b: s.floor(a / b),
    ast.Mod: operator.mod, ast.Pow: power,
}
FUNCTIONS = {
    'sqrt': s.sqrt, 'abs': s.Abs, 'ln': s.log, 'log10': lambda x: s.log(x, 10),
    'sin': s.sin, 'cos': s.cos, 'tan': s.tan,
    'asin': s.asin, 'acos': s.acos, 'atan': s.atan, 'exp': s.exp,
    'gcd': lambda *args: s.Integer(math.gcd(*(operator.index(arg) for arg in args))),
    'isqrt': lambda x: s.Integer(math.isqrt(operator.index(x))),
    'floor': s.floor, 'ceil': s.ceiling, 'round': round_number,
    'radians': lambda x: x * s.pi / 180,
    'factorial': lambda n: combinatorics(math.factorial, n),
    'comb': lambda n, k: combinatorics(math.comb, n, k),
    'perm': lambda n, k: combinatorics(math.perm, n, k),
}
CONSTANTS = {'pi': s.pi, 'e': s.E}
SYMBOL_OPERATORS = {ast.Add, ast.Sub, ast.Mult, ast.Div, ast.Pow}


def bounded(value):
    if value.is_real is not True or value.is_finite is not True:
        raise ValueError()
    for number in value.atoms(s.Rational):
        if max(int(number.p).bit_length(), int(number.q).bit_length()) > MAX_BITS:
            raise ValueError()
    return value


def evaluate(node, source, allow_x=False):
    if isinstance(node, ast.Constant):
        if type(node.value) is int:
            return bounded(s.Integer(node.value))
        if type(node.value) is float:
            literal = ast.get_source_segment(source, node).replace('_', '')
            exponent = literal.lower().partition('e')[2]
            if exponent and abs(int(exponent)) > 1000:
                raise ValueError()
            return bounded(s.Rational(literal))
    if isinstance(node, ast.Name):
        if allow_x and node.id == 'x':
            return X
        if node.id in CONSTANTS:
            return CONSTANTS[node.id]
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
        value = evaluate(node.operand, source, allow_x)
        return -value if isinstance(node.op, ast.USub) else value
    if isinstance(node, ast.BinOp) and type(node.op) in BINARY:
        left = evaluate(node.left, source, allow_x)
        right = evaluate(node.right, source, allow_x)
        operation = type(node.op)
        if left.free_symbols or right.free_symbols:
            if (operation not in SYMBOL_OPERATORS
                    or (operation is ast.Div and right.free_symbols)
                    or (operation is ast.Pow and right not in (0, 1, 2))):
                raise ValueError()
            value = BINARY[operation](left, right)
            if s.Poly(value, X).degree() > 2:
                raise ValueError()
            return value
        return bounded(BINARY[operation](left, right))
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id in FUNCTIONS and not node.keywords):
        return bounded(FUNCTIONS[node.func.id](
            *(evaluate(arg, source) for arg in node.args)
        ))
    raise ValueError()


def render(value):
    if not value.is_Rational or value.is_Integer:
        return str(value)
    # Preserve repeating decimals and very long terminating decimals as fractions.
    denominator = int(value.q)
    places = 0
    while denominator != 1 and places < 128:
        divisor = math.gcd(denominator, 10)
        if divisor == 1:
            return str(value)
        denominator //= divisor
        places += 1
    if denominator != 1:
        return str(value)
    scaled = abs(int(value.p)) * 10**places // int(value.q)
    digits = str(scaled).zfill(places + 1)
    return ('-' if value < 0 else '') + digits[:-places] + '.' + digits[-places:]


def solve(node, source):
    if node.keywords or len(node.args) not in (1, 2):
        raise ValueError()
    lhs = evaluate(node.args[0], source, allow_x=True)
    rhs = evaluate(node.args[1], source, allow_x=True) if len(node.args) == 2 else s.S.Zero
    # Restrict the solver to rational-coefficient real linear and quadratic equations.
    polynomial = s.Poly(lhs - rhs, X, domain=s.QQ)
    roots = s.solveset(polynomial.as_expr(), X, domain=s.S.Reals)
    if roots in (s.S.Reals, s.S.EmptySet):
        return 'R' if roots == s.S.Reals else '{}'
    if not isinstance(roots, s.FiniteSet):
        raise ValueError()
    return '{' + ', '.join(render(bounded(root)) for root in roots) + '}'


def calculate(expression):
    try:
        if not isinstance(expression, str) or not 1 <= len(expression) <= MAX_EXPRESSION_LENGTH:
            raise ValueError()
        source = expression.strip().translate(MATH_CHARACTERS)
        node = ast.parse(source, mode='eval').body
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'solve':
            result = {'value': solve(node, source)}
        else:
            value = evaluate(node, source)
            result = {'value': render(value)}
            if not value.is_Rational:
                try:
                    result['approx'] = str(value.evalf(16, maxn=100, strict=True))
                except PrecisionExhausted:
                    pass
        if len(result['value']) > 2048:
            raise ValueError()
        return result
    except (ArithmeticError, TypeError, ValueError, SyntaxError, RecursionError,
            s.PolynomialError, s.CoercionFailed, PrecisionExhausted):
        return {'invalid': True}


def main():
    try:
        request = json.loads(sys.stdin.buffer.readline(16384))
    except (ValueError, RecursionError):
        request = None
    if isinstance(request, list) and 1 <= len(request) <= MAX_BATCH_SIZE:
        result = {'results': [calculate(expression) for expression in request]}
    else:
        result = calculate(request)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
