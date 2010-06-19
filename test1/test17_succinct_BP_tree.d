/*
 * BP (balanced parentheses) representation of static ordinal trees
 *
 * BP representation consume only 2 bit per node for maintaining a tree
 * structure, while the normal parent-sibling-child pointers consume 96
 * or 192 bit per node.
 *
 *     struct Node {
 *         Node* parent, sibling, child;    // 96 or 192 bit
 *         T     data;
 *     }
 *
 *     struct BP_Tree {
 *         bit[] P;                         // 2 bit per node
 *         T[]   data;
 *     }
 *
--------------------
% rdmd -unittest test17_succinct_BP_tree
size of tree            11 nodes
e's depth               4
g's parent              c
h's next sibling        k
BP size                 22 bit
% _
--------------------
 */

import std.contracts;
import std.stdio;

void main()
{
    /*
     *    .------- a --------.
     *   /      /     \       \
     *  b      c       h       k
     *        / \     / \
     *       d   g   i   j
     *      / \
     *     e   f
     *
     * Paren maintains only a tree structure -- data and/or node labels
     * must be held elsewhere (data is stored in array in this code).
     */
    Paren structure = Paren("(()((()())())(()())())");
    dchar[] data = [ 'a', 'b', 'c', 'd', 'e', 'f',
                     'g', 'h', 'i', 'j', 'k' ];

    auto tree = Tree!dchar(structure, data);

    /*
     * How many nodes in the tree?
     */
    node_t root = 0;
    size_t size = subtreeSize(tree.structure, root);

    writefln("%-24s%s nodes", "size of tree", size);
    assert(size == 11); // 11 nodes

    /*
     * What's the depth of e?
     */
    node_t e = 4;
    size_t de;
    {
        size_t pe = nodeToParen(tree.structure, e);
        de = depth(tree.structure, pe);
    }
    writefln("%-24s%s", "e's depth", de);
    assert(de == 4); // it's 4

    /*
     * What's the parent of g?
     */
    node_t g = 6;
    node_t x;
    {
        size_t pg = nodeToParen(tree.structure, g);
        size_t px = parent(tree.structure, pg);
        x = parenToNode(tree.structure, px);
    }
    writefln("%-24s%s", "g's parent", tree.data[x]);
    assert(tree.data[x] == 'c'); // it's c

    /*
     * What's the next sibling of h?
     */
    node_t h = 7;
    node_t y;
    {
        size_t ph = nodeToParen(tree.structure, h);
        size_t py = nextSibling(tree.structure, ph);
        y = parenToNode(tree.structure, py);
    }
    writefln("%-24s%s", "h's next sibling", tree.data[y]);
    assert(tree.data[y] == 'k'); // it's k

    /*
     * How many bits consumed to hold the tree structure?
     */
    size_t nbits = tree.structure.length;

    writefln("%-24s%s bit", "BP size", nbits);
    assert(nbits == 22); // 22 bit.
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// parentheses
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * Succint representation of a static (immutable) tree
 */
struct Paren
{
    /*
     * Constructs a parentheses vector with its binary representation, i.e.
     * a sequence of bits.
     */
    this(immutable(ubyte)[] rep, size_t length)
    in
    {
        assert(rep.length * 8 >= length);
    }
    body
    {
        parens_ = rep.ptr;
        length_ = length;
    }


    /*
     * Constructs a parentheses vector with its string representation,
     * i.e. a sequence of open and close parenthesis characters.
     */
    this(string rep)
    {
        auto parens = new ubyte[(rep.length + 7) / 8];

        foreach (i, ch; rep)
        {
            final switch (ch)
            {
                case '(':
                    parens[i / 8] |= 1u << (i % 8);
                    break;

                case ')':
                    break;
            }
        }
        this(assumeUnique(parens), rep.length);
    }

    unittest
    {
        Paren P = Paren("((()())()())");
        assert(P.length == 12);
        assert(P.dump[0] == 0b10010111);
        assert(P.dump[1] == 0b____0010);
    }


    //--------------------------------------------------------------------//
    // primitive operations
    //--------------------------------------------------------------------//

    /*
     * Returns P[i] as an open/close parenthesis character.
     */
    dchar opIndex(size_t i) const pure nothrow @safe
    in
    {
        assert(i < length_);
    }
    body
    {
        return ((parens_[i / 8] >> (i % 8)) & 1) ? '(' : ')';
    }

    unittest
    {
        Paren P = Paren("((()())()())");
        ubyte[] ww = [ 1,1,1,0,1,0,0,1,0,1,0,0 ];
        foreach (i, w; ww)
            assert(P[i] == (w ? '(' : ')'));
    }


    /*
     * Returns the number of parentheses in the vector.
     */
    size_t length() const pure nothrow @property @safe
    {
        return length_;
    }


    /*
     * Returns the binary representation of the vector.  The dump data can
     * safely be written to an external storage, and the paren structure can
     * be restored by passing the dump data to Paren's constructor.
     */
    immutable(ubyte)[] dump() const pure nothrow @safe
    {
        return parens_[0 .. (length_ + 7) / 8];
    }


    //--------------------------------------------------------------------//
private immutable:
    ubyte* parens_;     // parentheses vector
    size_t length_;     // number of bits in the vector
}


//----------------------------------------------------------------------------//
// paren primitive queries
//----------------------------------------------------------------------------//

// XXX: Time complexities of these queries must be optimized to O(1), or at
//      least O(log n).  Basic way to achieve O(1) is just to make a table of
//      answers for each query -- with extra o(n) storages.
//
// - http://www.siam.org/proceedings/soda/2010/SODA10_013_sadakanek.pdf
// - http://zeno.siam.org/proceedings/alenex/2010/alx10_009_arroyuelod.pdf

/*
 * Returns the position of close parenthesis matching P[i].
 */
size_t findClose(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
out(r)
{
    assert(r > i);
    assert(paren[r] == ')');
}
body
{
    // BUG: O(n)
    size_t nest = 1;
    for (size_t j = i; ++j < paren.length; )
        if (paren[j] == '(')
            ++nest;
        else if (--nest == 0)
            return j;
    assert(0);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(findClose(P, 0) == 11);
    assert(findClose(P, 1) == 6);
    assert(findClose(P, 2) == 3);
    assert(findClose(P, 4) == 5);
    assert(findClose(P, 7) == 8);
    assert(findClose(P, 9) == 10);
}


/*
 * Returns the position of open parenthesis matching P[i].
 */
size_t findOpen(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == ')');
}
out(r)
{
    assert(r < i);
    assert(paren[r] == '(');
}
body
{
    // BUG: O(n)
    size_t nest = 1;
    for (size_t j = i; j-- > 0; )
        if (paren[j] == ')')
            ++nest;
        else if (--nest == 0)
            return j;
    assert(0);
}

unittest
{
    Paren P = Paren("(()())");
    assert(findOpen(P, 2) == 1);
    assert(findOpen(P, 4) == 3);
    assert(findOpen(P, 5) == 0);
}


/*
 * Returns the position of tightest open paren enclosing P[i].
 */
size_t enclose(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(i >= 1);
    assert(paren[i] == '(');
}
out(r)
{
    assert(r < i);
    assert(paren[r] == '(');
}
body
{
    // BUG: O(n)
    size_t nest = 1;
    for (size_t j = i; j-- > 0; )
        if (paren[j] == ')')
            ++nest;
        else if (--nest == 0)
            return j;
    assert(0);
}

unittest
{
    Paren P = Paren("(()(()()))");
    assert(enclose(P, 1) == 0);
    assert(enclose(P, 3) == 0);
    assert(enclose(P, 4) == 3);
    assert(enclose(P, 6) == 3);
}


/*
 * Returns the number of open/close parentheses in P[0,i].
 */
size_t rank(dchar c)(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(c == '(' || c == ')');
    assert(i < paren.length);
}
body
{
    // BUG: O(i)
    size_t rank;
    for (size_t j = i + 1; j-- > 0; )
        if (paren[j] == c)
            ++rank;
    return rank;
}

unittest
{
    Paren P = Paren("(()((()())())(()())())");
    assert(rank!'('(P, 0) == 1);
    assert(rank!'('(P, 1) == 2);
    assert(rank!'('(P, 2) == 2);
    assert(rank!'('(P, 3) == 3);
    assert(rank!'('(P, 4) == 4);
    assert(rank!'('(P, 5) == 5);
    assert(rank!')'(P, 0) == 0);
    assert(rank!')'(P, 1) == 0);
    assert(rank!')'(P, 2) == 1);
    assert(rank!')'(P, 21) == 11);
}


/*
 * Returns the position of i-th open/close parenthesis.
 */
size_t select(dchar c)(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(c == '(' || c == ')');
}
body
{
    // BUG: O(n)
    size_t count;
    for (size_t j = 0; j < paren.length; ++j)
        if (paren[j] == c && count++ == i)
            return j;
    assert(0);
}

unittest
{
    Paren P = Paren("(()((()())())(()())())");
    assert(select!'('(P, 0) == 0);
    assert(select!'('(P, 1) == 1);
    assert(select!'('(P, 2) == 3);
    assert(select!'('(P, 3) == 4);
    assert(select!'('(P, 4) == 5);
    assert(select!'('(P, 5) == 7);
    assert(select!'('(P, 10) == 19);
    assert(select!')'(P, 0) == 2);
    assert(select!')'(P, 5) == 12);
    assert(select!')'(P, 10) == 21);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// succint tree structure (BP representation)
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

struct Tree(T)
{
    Paren structure;
    T[]   data;
}


//----------------------------------------------------------------------------//
// node-paren convertion
//----------------------------------------------------------------------------//

// index of a node in an ordinal tree, starting from 0 (root)
alias size_t node_t;

/*
 * Returns the node index corresponding to i.
 */
node_t parenToNode(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    return rank!'('(paren, i) - 1;
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(parenToNode(P, 0) == 0);
    assert(parenToNode(P, 1) == 1);
    assert(parenToNode(P, 2) == 2);
    assert(parenToNode(P, 4) == 3);
    assert(parenToNode(P, 7) == 4);
    assert(parenToNode(P, 9) == 5);
}


/*
 * Returns the parenthesis index corresponding to node n.
 */
size_t nodeToParen(Paren paren, node_t n) pure nothrow @safe
out(r)
{
    assert(paren[r] == '(');
}
body
{
    return select!'('(paren, n);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(nodeToParen(P, 0) == 0);
    assert(nodeToParen(P, 1) == 1);
    assert(nodeToParen(P, 2) == 2);
    assert(nodeToParen(P, 3) == 4);
    assert(nodeToParen(P, 4) == 7);
    assert(nodeToParen(P, 5) == 9);
}


//----------------------------------------------------------------------------//
// additional paren queries
//----------------------------------------------------------------------------//

// ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' //
// node property
// . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . //

/*
 * Returns true iff i is a leaf node.
 */
bool isLeaf(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    // i( i)
    //     ^
    //     i+1

    return paren[i + 1] == ')';
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(!isLeaf(P, 0));
    assert(!isLeaf(P, 1));
    assert(isLeaf(P, 2));
    assert(isLeaf(P, 4));
    assert(isLeaf(P, 7));
    assert(isLeaf(P, 9));
}

/*
 * Returns true iff i is an ancestor of j.
 */
bool isAncestor(Paren paren, size_t i, size_t j) pure nothrow @safe
in
{
    assert(paren[i] == '(');
    assert(paren[j] == '(');
}
body
{
    // j( ... i( ... i) ... j)
    //                ^      ^
    //                ^      findclose(j)
    //                findclose(i)

    return j <= i && findClose(paren, i) <= findClose(paren, j);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(isAncestor(P, 2, 0));
    assert(isAncestor(P, 2, 1));
    assert(isAncestor(P, 4, 0));
    assert(isAncestor(P, 4, 1));
    assert(!isAncestor(P, 2, 4));
    assert(!isAncestor(P, 7, 2));
}

/*
 * Returns true iff i is the first sibling.
 */
bool isFirstSibling(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    // ( i( i) ( ) ... )
    // ^
    // i-1

    return i == 0 || paren[i - 1] == '(';
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(isFirstSibling(P, 0));
    assert(isFirstSibling(P, 1));
    assert(isFirstSibling(P, 2));
    assert(!isFirstSibling(P, 4));
    assert(!isFirstSibling(P, 7));
    assert(!isFirstSibling(P, 9));
}

/*
 * Returns true iff i is the last sibling.
 */
bool isLastSibling(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    // ( ... ( ) i( i) )
    //               ^
    //               findclose(i)

    return i == 0 || paren[findClose(paren, i) + 1] == ')';
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(isLastSibling(P, 0));
    assert(!isLastSibling(P, 1));
    assert(!isLastSibling(P, 2));
    assert(isLastSibling(P, 4));
    assert(!isLastSibling(P, 7));
    assert(isLastSibling(P, 9));
}

/*
 * Returns the depth of i.
 */
size_t depth(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    // +1+1  +1 +1  rank1(i) = 4
    // v-v---v--v-
    // ( ( ) ( i(
    // ----^------
    //     -1       rank0(i) = 1

    return rank!'('(paren, i) - rank!')'(paren, i);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(depth(P, 0) == 1);
    assert(depth(P, 1) == 2);
    assert(depth(P, 2) == 3);
    assert(depth(P, 4) == 3);
    assert(depth(P, 7) == 2);
    assert(depth(P, 9) == 2);
}


// ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' ' //
// tree walking
// . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . //

/*
 * Returns the parenthesis id of the parent of i.
 */
size_t parent(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(i >= 1);
    assert(paren[i] == '(');
}
body
{
    // ( ( ) i( ... i) ...)
    // ^
    // enclose(i)

    return enclose(paren, i);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(parent(P, 1) == 0);
    assert(parent(P, 2) == 1);
    assert(parent(P, 4) == 1);
    assert(parent(P, 7) == 0);
    assert(parent(P, 9) == 0);
}


/*
 * Returns the parenthesis id of the first child of i.
 */
size_t firstChild(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
    assert(!isLeaf(paren, i));
}
body
{
    // i( ( ) ... i)
    //    ^
    //    i+1

    return i + 1;
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(firstChild(P, 0) == 1);
    assert(firstChild(P, 1) == 2);
}


/*
 * Returns the parenthesis id of the last child of i.
 */
size_t lastChild(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
    assert(!isLeaf(paren, i));
}
body
{
    // i( ... ( ... ) i)
    //        ^        ^
    //        ^        findclose(i)
    //        findopen

    return findOpen(paren, findClose(paren, i) - 1);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(lastChild(P, 0) == 9);
    assert(lastChild(P, 1) == 4);
}


/*
 * Returns the parenthesis id of the next sibling of i.
 */
size_t nextSibling(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
    assert(!isLastSibling(paren, i));
}
body
{
    // i( ... i) ( ...
    //         ^
    //         findclose(i)

    return findClose(paren, i) + 1;
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(nextSibling(P, 1) == 7);
    assert(nextSibling(P, 2) == 4);
    assert(nextSibling(P, 7) == 9);
}


/*
 * Returns the parenthesis id of the previous sibling of i.
 */
size_t prevSibling(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
    assert(!isFirstSibling(paren, i));
}
body
{
    // ( ... ) i( ...
    //       ^
    //       i-1

    return findOpen(paren, i - 1);
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(prevSibling(P, 4) == 2);
    assert(prevSibling(P, 7) == 1);
    assert(prevSibling(P, 9) == 7);
}


/*
 * Returns the number of nodes in the subtree of i.
 */
size_t subtreeSize(Paren paren, size_t i) pure nothrow @safe
in
{
    assert(paren[i] == '(');
}
body
{
    // i( ... i)
    //  <------>
    //   findClose(i)-i+1 parentheses

    return (findClose(paren, i) - i + 1) / 2;
}

unittest
{
    Paren P = Paren("((()())()())");
    assert(subtreeSize(P, 0) == 6);
    assert(subtreeSize(P, 1) == 3);
    assert(subtreeSize(P, 2) == 1);
    assert(subtreeSize(P, 4) == 1);
    assert(subtreeSize(P, 7) == 1);
    assert(subtreeSize(P, 9) == 1);
}

