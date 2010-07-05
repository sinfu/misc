
import std.typecons;

void main()
{
    auto i = wrap!FooBarInterface(new class
        {
            string foo()
            {
                return "foo";
            }
            int bar(int a)
            {
                return a * a;
            }
        });

    assert(i.foo() == "foo");
    assert(i.bar(4) == 4*4);
}

interface FooBarInterface
{
    string foo();
    int    bar(int);
}


//----------------------------------------------------------------------------//

// wrap
Interface wrap(Interface, O)(O o)
{
    // AutoImplement で ProxyBase を自動実装して，ProxyBase のコンストラクタに o を渡します．
    // 下の方にある ProxyBase を見てください．
    return new AutoImplement!(ProxyBase!(Interface, O), generateProxy)(o);
}


//
// Interface の各メソッドを実装するテンプレートです．
//
// C には ProxyBase が渡されます．
// func には実装する関数のシンボル (ProxyBase.foo など) が渡されます．
// __traits(identifier) を使うと関数名の文字列 "foo" が得られます．
//
// ★ func がタプルになっているのは BUG 4217 の回避用です．
// 本当は alias ですが，alias だとオーバーロードされたメソッドで変なことになります．
//
template generateProxy(C, /+alias+/ func...)
{
    enum string generateProxy =
        "return o." ~ __traits(identifier, func[0]) ~ "(args);";

}


//
// AutoImplement はただ abstract メソッドを実装するだけなので，Interface を直接
// 実装するのではなく，こうやって間に O のインスタンスを保持するクラスをはさんでください．
//
// ★ BUG 2525 & 3525 のせいで，あり得る interface すべてに対して ProxyBase を書かねばなりません．
//
abstract class ProxyBase(Interface, O)
        if (is(Interface == FooBarInterface))
    : Interface
{
    O o;

    this(O o)
    {
        this.o = o;
    }

    // ★ BUG 2525 & 3525 の回避…
    // 不便ですが，こうやって明示的にメソッドを並べておかないとコンパイルエラーになってしまいます．
    // このバグがなければ，上の数行だけであらゆるケースに対応できるのですが…．
    override abstract
    {
        string foo();
        int    bar(int);
    }
}


