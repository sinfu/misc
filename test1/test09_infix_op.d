/*
 * Parsing infix operator of arbitrary precedence (c.f. Haskell)
 *
 * Basic idea:
 *
 *   <infix[p] expr>
 *       ::=  <infix[p+1] expr> ( <infix[p] op> <infix[p+1] expr> )*
 *
 * where p is the precedence of an infix operator.
 */

import std.stdio;


void main()
{
    string source = "10 < 42 * (10 / 2 - 4) || 1 + 2 + 3 <= 5 || 0";

    auto expr = source.parseExpression();
    writeln("rest = ", source);
    writeln("expr = ", cast(Object) expr);
    writeln("eval = ", expr.eval);
}


//////////////////////////////////////////////////////////////////////////////

import std.algorithm;
import std.array;
import std.string;
import std.conv;

enum
{
    PAT_DIGIT      = "0-9",
    PAT_ALPHA      = "A-Za-z",
    PAT_SYMBOL     = `!#$%&*+./:<=>?@\^|~-`,
    PAT_WHITESPACE = "\t ",
}

interface Expression
{
    int eval();
}


Expression parseExpression(ref string source)
{
    return source.parseBinaryExpression();
}


////////////////////////////////////////////////

struct InfixOperator
{
    enum Assoc
    {
        LEFT,
        NONE,
        RIGHT,
    }
    string operator;
    Assoc associativity;

    string toString() const
    {
        return operator;
    }
}

enum uint MAX_INFIX_PRECEDENCE = 9;

static immutable InfixOperator[][MAX_INFIX_PRECEDENCE + 1]
    INFIX_OPERATORS =
[
    8: [ { "**", InfixOperator.Assoc.RIGHT }, ],
    7: [ {  "*", InfixOperator.Assoc.LEFT  },
         {  "/", InfixOperator.Assoc.LEFT  },
         {  "%", InfixOperator.Assoc.LEFT  }, ],
    6: [ {  "+", InfixOperator.Assoc.LEFT  },
         {  "-", InfixOperator.Assoc.LEFT  }, ],
    4: [ {  "=", InfixOperator.Assoc.NONE  },
         {  "<", InfixOperator.Assoc.NONE  },
         { "<=", InfixOperator.Assoc.NONE  },
         {  ">", InfixOperator.Assoc.NONE  },
         { ">=", InfixOperator.Assoc.NONE  }, ],
    3: [ { "&&", InfixOperator.Assoc.RIGHT }, ],
    2: [ { "||", InfixOperator.Assoc.RIGHT }, ],
];


/*
 * <infix[i] expr>
 *   ::=  <infix[i+1] expr> ( <infix[i]-X op> <infix[i+1] expr> )*
 *
 * <infix[i] expr # AmbiguousError>
 *   ::=  <infix[i] expr> <infix[i]-nonX op>
 *
 * --------------------
 * infixl e[k] =
 *   | k = 0  =>  a[0]
 *   | k > 0  =>  e[k-1] `op` a[k]
 *
 * infixr e[k] =
 *   | k = N  =>  a[k]
 *   | k < N  =>  a[k] `op` e[k+1]
 * --------------------
 */
Expression parseBinaryExpression(ref string source, uint precedence = 0)
{
    if (precedence > MAX_INFIX_PRECEDENCE)
    {
        return source.parseAtomicExpression();
    }

    auto expr = source.parseBinaryExpression(precedence + 1);

    if (auto operator = source.parseInfixOperator(precedence))
    {
        immutable expectedAssoc = operator.associativity;

        while (operator && operator.associativity == expectedAssoc)
        {
            auto rhs = source.parseBinaryExpression(
                expectedAssoc == InfixOperator.Assoc.LEFT ?
                    precedence + 1 : precedence );

            expr = new BinaryExpression(*operator, expr, rhs);

            // next
            operator = source.parseInfixOperator(precedence);
        }
    }

    return expr;
}


class BinaryExpression : public Expression
{
    InfixOperator m_operator;
    Expression    m_left, m_right;

    this(InfixOperator operator, Expression left, Expression right)
    {
        m_operator = operator;
        m_left     = left;
        m_right    = right;
    }

    override int eval()
    {
        immutable
            lhs = m_left .eval,
            rhs = m_right.eval;

        switch (m_operator.operator)
        {
            case  "*": return lhs  * rhs;
            case  "/": return lhs  / rhs;
            case  "%": return lhs  % rhs;
            case  "+": return lhs  + rhs;
            case  "-": return lhs  - rhs;
            case  "=": return lhs == rhs;
            case  "<": return lhs <  rhs;
            case "<=": return lhs <= rhs;
            case  ">": return lhs >  rhs;
            case ">=": return lhs >= rhs;
            case "&&": return lhs && rhs;
            case "||": return lhs || rhs;

            default: assert(0);
        }
    }

    override string toString() const
    {
        // LISP-style
        return
            "(" ~ m_operator.toString() ~ " " ~
            (cast(Object) m_left ).toString() ~ " " ~
            (cast(Object) m_right).toString() ~ ")";
    }
}


immutable(InfixOperator)*
    parseInfixOperator(ref string source, uint precedence)
{
    immutable operatorSet = INFIX_OPERATORS[precedence];

    auto      scratch = source;
    immutable symoper = scratch.munch(PAT_SYMBOL);
    scratch.skipWhitespace();

    auto operator = find!("a.operator == b")(operatorSet, symoper);

    if (!operator.empty)
    {
        source = scratch;
        return &operator.front;
    }
    else
        return null;
}


////////////////////////////////////////////////


Expression parseAtomicExpression(ref string source)
{
    if (source.removePrefix("("))
    {
        source.skipWhitespace();
        auto expr = source.parseExpression();
        source.removePrefix(")");
        source.skipWhitespace();

        return expr;
    }
    else if (source.startsWithPattern(PAT_DIGIT))
    {
        return new IntegerLiteralExpression(source.parseInteger());
    }
    assert(0);
}

int parseInteger(ref string source)
{
    immutable digits = source.munch(PAT_DIGIT);
    source.skipWhitespace();
    return to!(int)(digits);
}


class IntegerLiteralExpression : public Expression
{
    int m_value;

    this(int value)
    {
        m_value = value;
    }

    int eval() const
    {
        return m_value;
    }

    override string toString() const
    {
        return to!(string)(m_value);
    }
}


////////////////////////////////////////////////////////////////

bool startsWithPattern(string str, string pattern)
{
    return str.munch(pattern).length != 0;
}

bool removePrefix(ref string str, string prefix)
{
    if (str.startsWith(prefix))
    {
        str = str.chompPrefix(prefix);
        return true;
    }
    else
        return false;
}

void skipWhitespace(ref string str)
{
    return str.munch(PAT_WHITESPACE);
}


//////////////////////////////////////////////////////////////////////////////

__EOF__

/++++

========================================================
#              Builtin Infix Operators                 #
========================================================
| Prec | L-associative | N-associative | R-associative |
|------+---------------+---------------+---------------|
|    9 |               |               |               |
|    8 |               |               | **            |
|    7 | *,/,%         |               |               |
|    6 | +,-           |               |               |
|    5 |               |               |               |
|    4 |               | =,<,<=,>,>=   |               |
|    3 |               |               | &&            |
|    2 |               |               | ||            |
|    1 |               |               |               |
|    0 |               |               |               |
========================================================

References:
  - http://www.haskell.org/onlinereport/decls.html

--------------------------------------------------------

;; Expressions that contain infix operators with the
;; same precedence and different associativities are
;; syntactically ambiguous. There must be just one
;; associativity for each precedence in an expression.
;;
;; Example:
;; --------------------
;; {-
;;   Here's another plus operator <+>, which is right
;;   associative and has the same precedence as plus
;;   operator +.
;; -}
;; infixr 6 <+>
;; infixl 6  +
;;
;; {-
;;   "(1 <+> 2) + 3" or "1 <+> (2 + 3)" ??
;; -}
;; ambiguous = 1 <+> 2 + 3
;; --------------------

<infix[i] expression>
  ::=  <infix[i]-L expression>
    |  <infix[i]-N expression>
    |  <infix[i]-R expression>

;; Left associative operator: (x <op> y) <op> z
<infix[i]-L expression>
  ::=  <infix[i+1] expression>
    |  <infix[i]-L expression> <infix[i]-L operator> <infix[i+1] expression>

;; Nonassociative operator: x <op> y
<infix[i]-N expression>
  ::=  <infix[i+1] expression>
    |  <infix[i+1] expression> <infix[i]-N operator> <infix[i+1] expression>

;; Right associative operator: x <op> (y <op> z)
<infix[i]-R expression>
  ::=  <infix[i+1] expression>
    |  <infix[i+1] expression> <infix[i]-R operator> <infix[i]-R expression>


<infix[N] expression>
  ::=  <prefix expression>

<prefix expression>
  ::=  <prefix operator> <prefix expression>
    |  <atomic>

++++/


;; Left associative operator: (x <op> y) <op> z
<infix[i]-L expr>
  ::=  <infix[i+1] expr>
    |  <infix[i]-L expr> <infix[i]-L op> <infix[i+1] expr>

  ::=  ( <infix[i+1] expr> <infix[i]-L op> )* <infix[i+1] expr>

;; Nonassociative operator: x <op> y
;; It must be binomial.
<infix[i]-N expr>
  ::=  <infix[i+1] expr>
    |  <infix[i+1] expr> <infix[i]-N op> <infix[i+1] expr>

  ::=  <infix[i+1] expr> ( <infix[i]-N op> <infix[i+1] expr> )?

;; Right associative operator: x <op> (y <op> z)
<infix[i]-R expr>
  ::=  <infix[i+1] expr>
    |  <infix[i+1] expr> <infix[i]-R op> <infix[i]-R expr>

  ::=  <infix[i+1] expr> ( <infix[i]-R op> <infix[i+1] expr> )*


