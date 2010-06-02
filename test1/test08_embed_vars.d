/*
String-embedded variables.

--------------------
% dmd -run test08_embed_vars
nn == 42
op == 0 --> true
--------------------
 */

import std.stdio;
import std.conv;


struct req { int op; }

void main()
{
    int nn = 42;
    req z_req;

    writeln(mixin("nn == $nn\nop == 0 --> $(z_req.op == 0)".embed));
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * <variable-embedded string>
 *   ::=  <unit>*
 *
 * <unit>
 *   ::=  <embedded variable>
 *     |  <text string>
 *
 * <embedded variable>
 *   ::=  "$"     <name>
 *     |  "$" "(" <expression> ")"
 *     |  "$$"
 */
string embed(string s) pure nothrow @safe @property
{
    string units;
    string rep = s;

    while (rep.length)
    {
        string expr;

        if (units.length > 0)
            units ~= ", ";

        if (rep[0] == '$')
        {
            rep = rep[1 .. $];
            assert(rep.length > 0);

            if (rep[0] == '$')
            {
                expr = rep[0 .. 1];
                rep  = rep[1 .. $];
            }
            else if (rep[0] == '(')
            {
                rep  = rep[1 .. $];
                expr = rep.strtok(')');
                rep  = rep[expr.length .. $];
                rep  = rep[1 .. $];
            }
            else
            {
                expr = rep.nextok;
                rep  = rep[expr.length .. $];
            }
        }
        else
        {
            expr = rep.strtok('$');
            rep  = rep[expr.length .. $];
            expr = "`" ~ expr ~ "`";
        }

        units ~= expr;
    }

    return "std.conv.text(" ~ units ~ ")";
}

private string nextok(string str) pure nothrow @safe
{
    foreach (i, ch; str)
    {
        if (!('A' <= ch && ch <= 'Z') &&
            !('a' <= ch && ch <= 'z') &&
            !('0' <= ch && ch <= '9') &&
            !(ch == '_'))
        {
            return str[0 .. i];
        }
    }
    return str;
}

private string strtok(string str, char term) pure nothrow @safe
{
    foreach (i, ch; str)
    {
        if (ch == term)
            return str[0 .. i];
    }
    return str;
}

