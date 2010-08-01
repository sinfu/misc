/*
 * Range を使って平方根を求める．
 *
 * References:
 * -    元ネタ:  Scheme 入門 | 17. 遅延評価
 *               http://www.shido.info/lisp/scheme_lazy.html
 * - …の元ネタ:  なぜ関数プログラミングは重要か
 *               http://www.sampou.org/haskell/article/whyfp.html
 */

import std.algorithm;
import std.stdio;

void main()
{
    // double.max の正の平方根を計算する
    real x = double.max;

    // 収束するまで反復し続ける
    auto r = NewtonRaphsonSquareRoot(x);
    real y = findAdjacent(r).front;

    writefln("+sqrt %.*g  =  %.*g", x.dig + 1, x,
                                    y.dig + 1, y );
}


/*
 * Newton-Raphson 法による平方根計算機 (無限遅延リスト)．
 *
 * NOTES:
 *  std.range recurrence() はパラメータ (この場合 'number') が与えられない．
 *  とりあえず自家実装する．
 */
@safe struct NewtonRaphsonSquareRoot
{
  private:
    real head_;
    real number_;

  public:

    /**
     * 平方根を計算するための無限遅延リストをつくる．
     *
     * Params:
     *  number = 平方根を求める有限な非負数．
     *  start  = 反復計算の初期値．ゼロでない有限な数を指定する．計算結果の
     *     符号は $(D start) のものと同じになる．つまり，$(D start) が負数
     *     ならば負の平方根が計算される．
     */
    this(real number, real start = 1) nothrow
    in
    {
        assert(number >= 0);
        assert(number < real.infinity);
        assert(start != 0);
        assert(-real.infinity < start && start < real.infinity);
    }
    body
    {
        head_   = start;
        number_ = number;
    }


    //----------------------------------------------------------------//
    // Input range primitives
    //----------------------------------------------------------------//

    enum bool empty = false;

    @property real front() const nothrow
    {
        return head_;
    }

    void popFront()
    {
        head_ += number_ / head_;
        head_ /= 2;
    }


    //----------------------------------------------------------------//
    // Forward range primitive
    //----------------------------------------------------------------//

    @property typeof(this) save() const nothrow
    {
        return this;
    }
}

unittest
{
    auto r = NewtonRaphsonSquareRoot(1.0L);
    auto s = NewtonRaphsonSquareRoot(1.0L,  2.0L);
    auto t = NewtonRaphsonSquareRoot(0.0L, -1.0L);

    r.popFront();
    assert(!r.empty);

    assert(s.front ==  2.0L);
    assert(t.front == -1.0L);
}

