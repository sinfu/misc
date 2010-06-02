/*
Match-When syntax.

--------------------
% dmd -run test07_match_when
121 is divisible by 11
12321 is divisible by 3
1234321 is divisible by 11
123454321 is not divisible neither by 3 nor 11
12345654321 is divisible by 3
--------------------
 */

import std.stdio;

void main()
{
    auto examples = [ 121, 12321, 1234321, 123454321, 12345654321 ];

    foreach (n; examples)
    {
        with (match! "a % b == 0" (n))
        {
            if (when(3))
                writeln(n, " is divisible by 3");

            if (when(11))
                writeln(n, " is divisible by 11");

            if (otherwise)
                writeln(n, " is not divisible neither by 3 nor 11");
        }
    }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import std.functional;


class Match(alias pred, T)
{
    bool when(U)(U rhs)
    {
        if (pred(value_, rhs))
            return hit_ = true;
        else
            return false;
        //return !hit_ && (hit_ = pred(value_, rhs));
    }

    bool otherwise()
    {
        return !hit_;
    }

private:
    T    value_;
    bool hit_;

    this(T value)
    {
        value_ = value;
    }
}

auto match(alias pred, T)(T value)
{
    return new Match!(binaryFun!(pred), T)(value);
}

