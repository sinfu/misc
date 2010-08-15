/**
 * Macros:
 *  D = $(I $1)
 */
module test29_staticset;

import std.typetuple : TypeTuple;


void main()
{
    //
    // StaticSort
    //
    alias StaticSort!(standardLess, 5, 1, 3, 2, 4) s;
    static assert([ s ] == [ 1, 2, 3, 4, 5 ]);

    alias StaticSort!(heterogeneousLess,  main, "abc",   int,    64,    42, "xyz") h1;
    alias StaticSort!(heterogeneousLess, "abc",   int,    42,  main, "xyz",    64) h2;
    alias StaticSort!(heterogeneousLess, "xyz",  main, "abc",    64,   int,    42) h3;

    pragma(msg, "Heterogeneous sort 1 -> ", h1);
    pragma(msg, "Heterogeneous sort 2 -> ", h2);
    pragma(msg, "Heterogeneous sort 3 -> ", h3);

    //
    // StaticSet
    //
    alias StaticSet!(main, "set",  1.5, main,   int) A;
    alias StaticSet!( int,   1.5,  1.5, main, "set") B;
    alias StaticSet!( 1.5,   int, main, main, "set") C;

    static assert(__traits(isSame, A, B));
    static assert(__traits(isSame, B, C));

    static assert(A.equals!(B));
    static assert(A.equals!(C));
}


//----------------------------------------------------------------------------//
// Static Set
//----------------------------------------------------------------------------//

// Supplied arguments always get normalized via this hook, so that ALL
// the following instantiations:
//
//      StaticSet!(2,1,3)  StaticSet!(3,1,2)  StaticSet!(1,1,3,2)
//
// yield the single instance StaticSet!(1,2,3).

template StaticSet(items...)
    if (!isNormalizedForSet!(items))
{
    alias StaticSet!(NormalizeForSet!(items)) StaticSet;
}


// Normalizes the tuple items for StaticSet.  The items are rearranged in
// a certain order, and any duplicated items are eliminated.
private template NormalizeForSet(items...)
{
    alias StaticUniq!(StaticSort!(heterogeneousLess, items)) NormalizeForSet;
}

unittest
{
    alias NormalizeForSet!() e;
    assert(e.length == 0);
}

unittest
{
    alias NormalizeForSet!(1) I;
    assert(I.length == 1);
    assert(I[0] == 1);

    alias NormalizeForSet!(1, 1, 1, 1, 1) II;
    assert(II.length == 1);
    assert(II[0] == 1);
}

unittest
{
    alias NormalizeForSet!(char, int, real, int, int) N;
    assert(N.length == 3);
    assert(!is( N[0] == N[1] ));
    assert(!is( N[1] == N[2] ));
    assert(!is( N[2] == N[1] ));
}


// Sees if the tuple items is already normalized or not.
private template isNormalizedForSet(items...)
{
    // TODO: optimize
    enum isNormalizedForSet =
            is( Entity!(                 items ).ToType ==
                Entity!(NormalizeForSet!(items)).ToType );
}


// For detecting StaticSet instances. (Used by isStaticSet below below...)
private struct StaticSetTag {}


/**
 * TODO
 */
template StaticSet(items...)
    if (isNormalizedForSet!(items))
{
private:
    alias StaticSetTag      ContainerTag;   // for isStaticSet
    alias StaticSet!(items) This;           // reference to itself


public:
    //----------------------------------------------------------------//
    // Properties
    //----------------------------------------------------------------//

    /**
     * Returns $(D true) if and only if the set is _empty.
     */
    enum bool empty = (items.length == 0);


    /**
     * The number of elements in the set.
     */
    enum size_t length = items.length;


    /**
     * The _elements in the set.
     *
     * The order of $(D elements) is not always the same as the that of the
     * instantiation arguments $(D items).
     */
    alias items elements;


    //----------------------------------------------------------------//
    // Set Comparison
    //----------------------------------------------------------------//

    /**
     * Compares the set with $(D rhs) for equality.
     *
     * Params:
     *  rhs = A $(D StaticSet) instance or an immediate tuple to compare.
     *
     * Returns:
     *  $(D true) if the two sets are the same, or $(D false) otherwise.
     */
    template equals(alias rhs)
        if (isStaticSet!(rhs))
    {
        // Note: Template instances have the same symbol if and only if they
        //       have been instantiated with the same arguments.
        enum equals = __traits(isSame, This, rhs);
    }

    /// ditto
    template equals(rhs...)
    {
        enum equals = equals!(StaticSet!(rhs));
    }


    /**
     * Determines if $(D rhs) is a subset of this set.
     *
     * Params:
     *  rhs = A $(D StaticSet) instance or an immediate tuple to compare.
     *
     * Returns:
     *  $(D true) if $(D rhs) is a subset of this set, or $(D false) otherwise.
     */
    template contains(alias rhs)
        if (isStaticSet!(rhs))
    {
        enum contains = true;   // TODO
    }

    /// ditto
    template contains(rhs...)
    {
        enum contains = contains!(StaticSet!(rhs));
    }
}

unittest
{
    alias StaticSet!() e;
    assert(e.empty);
    assert(e.length == 0);
    assert(e.elements.length == 0);

    alias StaticSet!(1) I;
    assert(!I.empty);
    assert( I.length == 1);
    assert( I.elements.length == 1);
    assert( I.elements[0] == 1);

    alias StaticSet!("dee") D;
    assert(!D.empty);
    assert( D.length == 1);
    assert( D.elements.length == 1);
    assert( D.elements[0] == "dee");

    alias StaticSet!(StaticSet) S;
    assert(!S.empty);
    assert( S.length == 1);
    assert( S.elements.length == 1);
    assert(__traits(isSame, S.elements[0], StaticSet));

    alias StaticSet!(S) M;
    assert(!M.empty);
    assert( M.length == 1);
    assert( M.elements.length == 1);
    assert(__traits(isSame, M.elements[0], S));

    alias StaticSet!(real) T;
    assert(!T.empty);
    assert( T.length == 1);
    assert( T.elements.length == 1);
    assert(is( T.elements[0] == real ));
}

unittest
{
    alias StaticSet!(1, 2, 3, 2, 1) S_12321;
    alias StaticSet!(1, 2, 3      ) S_123__;
    alias StaticSet!(   2, 3,    1) S__23_1;

    assert(!S_12321.empty);
    assert( S_12321.length == 3);
    assert( S_12321.elements.length == 3);

    assert(__traits(isSame, S_12321, S_123__));
    assert(__traits(isSame, S_123__, S__23_1));
}

unittest
{
    alias StaticSet!(-1.0,  real,     "dee", StaticSet) A;
    alias StaticSet!(real, "dee", StaticSet,      -1.0) B;

    assert(!A.empty);
    assert( A.length == 4);
    assert( A.elements.length == 4);

    assert(__traits(isSame, A, B));
}

unittest
{
    alias StaticSet!(1, 2, 3, 4   ) A;
    alias StaticSet!(   2, 3, 4   ) B;
    alias StaticSet!(1, 2, 3, 4, 5) C;
    alias StaticSet!("12345", real) D;
    alias StaticSet!(             ) E;

    assert( A.equals!(A));
    assert(!A.equals!(B));
    assert(!A.equals!(C));
    assert(!A.equals!(D));
    assert(!A.equals!(E));
}

unittest
{
    alias StaticSet!(1, 2, 3, 4) A;
    assert( A.equals!(   1, 2, 3, 4));
    assert( A.equals!(   2, 4, 3, 1));
    assert( A.equals!(1, 1, 2, 3, 4));
    assert(!A.equals!(0, 1, 2, 3, 4));
    assert(!A.equals!(      2, 3, 4));
    assert(!A.equals!(             ));
}

unittest
{
    alias StaticSet!("12345",    real) D;
    assert(D.equals!("12345",    real));
    assert(D.equals!(   real, "12345"));
}

unittest
{
    alias StaticSet!() E;
    assert(E.equals!(E));
    assert(E.equals!( ));
}

unittest
{
    alias StaticSet!(1, 2, 3, 4) A;
    alias StaticSet!(          ) E;
    alias StaticSet!(1         ) A_1___;
    alias StaticSet!(1, 2, 3   ) A_123_;
    alias StaticSet!(   2, 3, 4) A__234;

    assert(A.contains!(E));
    assert(A.contains!(A_1___));
    assert(A.contains!(A_123_));
    assert(A.contains!(A__234));
}


/**
 * Returns $(D true) iff $(D set) is an instance of the $(D StaticSet).
 */
template isStaticSet(alias set)
{
    enum isStaticSet = is(set.ContainerTag == StaticSetTag);
}

/// ditto
template isStaticSet(set)
{
    enum isStaticSet = false;
}

unittest
{
    alias StaticSet!(          ) A;
    alias StaticSet!(1         ) B;
    alias StaticSet!(2, int    ) C;
    alias StaticSet!(3, real, A) D;

    assert(isStaticSet!(A));
    assert(isStaticSet!(B));
    assert(isStaticSet!(C));
    assert(isStaticSet!(D));
}

unittest
{
    struct Set {}
    assert(!isStaticSet!(int));
    assert(!isStaticSet!(Set));
    assert(!isStaticSet!(123));
    assert(!isStaticSet!(isStaticSet));
    assert(!isStaticSet!(  StaticSet)); // not an instance
}


//
// TODO ========================================================
//

/**
 *
 */
template StaticSetIntersection(alias A, alias B)
    if (isStaticSet!(A) && isStaticSet!(B))
{
}

unittest
{
}


/**
 *
 */
template StaticSetUnion(alias A, alias B)
    if (isStaticSet!(A) && isStaticSet!(B))
{
}

unittest
{
}


/**
 *
 */
template StaticSetDifference(alias A, alias B)
    if (isStaticSet!(A) && isStaticSet!(B))
{
}

unittest
{
}


/**
 *
 */
template StaticSetSymmetricDifference(alias A, alias B)
    if (isStaticSet!(A) && isStaticSet!(B))
{
}

unittest
{
}


//----------------------------------------------------------------------------//
// Sorting Compile-Time Entities
//----------------------------------------------------------------------------//

/**
 * Sorts $(D items) with a comparator $(D less) and returns the sorted tuple.
 *
 * Params:
 *  less  = Comparator template that abstracts the $(D <) operator.  See the
 *          example below for more details.
 *  items = Compile-time entities to sort.  Every entities must be comparable
 *          with each other by the $(D less) template.
 *
 * Example:
 *  The following code sorts the sequence $(D (5, 1, 4, 2, 3)) with a custom
 *  less operator $(D myLess).
--------------------
template myLess(int a, int b)
{
    enum bool myLess = (a < b);
}
alias TypeTuple!(5, 1, 4, 2, 3) sequence;
alias StaticSort!(myLess, sequence) result;

static assert([ result ] == [ 1, 2, 3, 4, 5 ]);
--------------------
 */
template StaticSort(alias less, items...)
{
    alias MergeSort!(less, items).result StaticSort;
}

unittest
{
}


//
// StaticSort uses the merge sort algorithm under the hood.
//

private template MergeSort(alias less, items...)
    if (items.length < 2)
{
    alias items result;
}

private template MergeSort(alias less, items...)
    if (items.length >= 2)
{
    template Merge(sortA...)
    {
        template With(sortB...)
        {
            static if (sortA.length == 0)
            {
                alias sortB With;
            }
            else static if (sortB.length == 0)
            {
                alias sortA With;
            }
            else
            {
                static if (less!(sortA[0], sortB[0]))
                    alias TypeTuple!( sortA[0], Merge!(sortA[1 .. $])
                                                .With!(sortB        ) ) With;
                else
                    alias TypeTuple!( sortB[0], Merge!(sortA        )
                                                .With!(sortB[1 .. $]) ) With;
            }
        }
    }

    alias Merge!(MergeSort!(less, items[  0 .. $/2]).result)
          .With!(MergeSort!(less, items[$/2 .. $  ]).result) result;
}


//----------------------------------------------------------------------------//
// Tiarg Comparator
//----------------------------------------------------------------------------//

/**
 * Compares compile-time constants $(D items...) with the built-in less
 * operator $(D <).  Values in $(D items...) must be comparable with each
 * other.
 *
 * Params:
 *  items = Compile-time constants or expressions to compare.  Instantiation
 *          fails if $(D items) contains only zero or one entity, or if it
 *          contains any non-comparable entities.
 *
 * Example:
 *  In the following code, a generic algorithm $(D TrimIncreasingPart) takes
 *  a comparator template $(D less) and performs certain operation on $(D seq).
 *  Here $(D standardLess) is used for the $(D less) argument.
--------------------
template TrimIncreasingPart(alias less, seq...)
{
    static if (seq.length >= 2 && less!(seq[0], seq[1]))
        alias TrimIncreasingPart!(less, seq[1 .. $]) TrimIncreasingPart;
    else
        alias                           seq          TrimIncreasingPart;
}

// Remove the first increasing part (0, 1, 2) of the original sequence.
alias TypeTuple!(0, 1, 2, 3.5, 2, 1) sequence;
alias TrimIncreasingPart!(standardLess, sequence) result;

// The result is (3.5, 2, 1).
static assert([ result ] == [ 3.5, 2, 1 ]);
--------------------
 */
template standardLess(items...)
{
    static assert(items.length >= 2);

    static if (items.length > 2)
    {
        enum bool standardLess = standardLess!(items[0 .. 2]) &&
                                 standardLess!(items[1 .. $]);
    }
    else
    {
        // Note: Use static this so that the expression is evaluated now.
        static if (items[0] < items[1])
            enum bool standardLess =  true;
        else
            enum bool standardLess = false;
    }
}

unittest
{
    assert( standardLess!(1, 2));
    assert( standardLess!(1, 2, 3, 4, 5));
    assert(!standardLess!(2, 1));
    assert(!standardLess!(5, 4, 3, 2, 1));
    assert(!standardLess!(1, 2, 3, 5, 4));
    assert(!standardLess!(1, 2, 4, 3, 5));
}

unittest
{
    assert( standardLess!(-1, -0.5, -0.1L));
    assert(!standardLess!( 1,  0.5,  0.1L));
    assert( standardLess!("A", "B", "C"));
    assert(!standardLess!("c", "b", "a"));
}

unittest
{
    assert(!__traits(compiles, standardLess!()));
    assert(!__traits(compiles, standardLess!(1)));
    assert(!__traits(compiles, standardLess!(123, "45")));
    assert(!__traits(compiles, standardLess!(int, char)));
    assert(!__traits(compiles, standardLess!(123, char)));
    assert(!__traits(compiles, standardLess!(123, standardLess)));
}


/**
 * Compares compile-time entities $(D items...) by their mangled name.
 * The tuple $(D items) can consist of any kind of compile-time entities
 * (unlike the restrictive $(D standardLess) template).
 *
 * The point of this template is to allow comparison against types and symbols
 * so that one can normalize a tuple by sorting it.  See also $(D StaticSort).
 *
 * Note that the result of comparison may be counter-intuitive since mangled
 * names are used.  For example, $(D heterogeneousLess!(-1, 1)) evaluates to
 * $(D false) whereas -1 is mathematically less than 1.
 */
template heterogeneousLess(items...)
{
    static assert(items.length >= 2);

    static if (items.length > 2)
        enum bool heterogeneousLess = heterogeneousLess!(items[0 .. 2]) &&
                                      heterogeneousLess!(items[1 .. $]);
    else
        enum bool heterogeneousLess = (Id!(items[0]) < Id!(items[1]));
}

// Returns the mangled name of entities.
private template Id(entities...)
{
    // TODO: optimize
    enum string Id = Entity!(entities).ToType.mangleof;
}

// Helper template for obtaining the mangled name of entities.
private template Entity(entities...)
{
    struct ToType {}
}

unittest
{
    assert( heterogeneousLess!(1, 2));
    assert(!heterogeneousLess!(2, 1));
    assert( heterogeneousLess!(1, 2, 3, 4));
    assert(!heterogeneousLess!(1, 3, 2, 4));

    assert(!heterogeneousLess!(-1,  1));
    assert( heterogeneousLess!( 1, -1));
}

unittest
{
    static assert(char.mangleof == "a");
    static assert(real.mangleof == "e");
    static assert( int.mangleof == "i");
    static assert(bool.mangleof == "b");
    assert( heterogeneousLess!(char, real,  int));
    assert(!heterogeneousLess!(bool, real, char));

    struct A {}
    struct B {}
    struct C {}
    assert( heterogeneousLess!(A, B));
    assert( heterogeneousLess!(B, C));
    assert( heterogeneousLess!(A, B, C));
    assert(!heterogeneousLess!(B, C, A));
}

unittest
{
    assert( heterogeneousLess!(standardLess, heterogeneousLess));
    assert(!heterogeneousLess!(standardLess, int));
}


/*
 * Determines if elements in $(D items) can be compared using comparator
 * template $(D op).  The result is $(D false) if $(D items) contains only
 * zero or one entity since comparison can't be defined.
 */
private template areComparable(alias op, items...)
{
    enum bool areComparable =
        (items.length >= 2 && __traits(compiles, op!(items)));
}

unittest
{
    assert( areComparable!(standardLess, 1, 2));
    assert( areComparable!(standardLess, 1, 2, 3));
    assert( areComparable!(standardLess, 1, 2, 3, 4.0, 3, 2.0));
    assert(!areComparable!(standardLess));
    assert(!areComparable!(standardLess, 1));
    assert(!areComparable!(standardLess, int));
    assert(!areComparable!(standardLess, int, char, string));
    assert(!areComparable!(standardLess, 1, 2, string));

    assert( areComparable!(heterogeneousLess, 1, 2));
    assert( areComparable!(heterogeneousLess, 1, 2, 3));
    assert( areComparable!(heterogeneousLess, int, char));
    assert( areComparable!(heterogeneousLess, int, char, string));
    assert(!areComparable!(heterogeneousLess));
    assert(!areComparable!(heterogeneousLess, int));
    assert(!areComparable!(heterogeneousLess, 1));
}


/*
 * Returns the appropriate comparator template for the entities $(D items).
 */
private template adaptiveLessFor(items...)
{
    static if (areComparable!(standardLess, items))
        alias      standardLess adaptiveLessFor;
    else
        alias heterogeneousLess adaptiveLessFor;
}

unittest
{
    assert(__traits(isSame, standardLess, adaptiveLessFor!(1.2, 3.4)));
    assert(__traits(isSame, standardLess, adaptiveLessFor!("a", "b")));
    assert(__traits(isSame, standardLess, adaptiveLessFor!(1, 2, 3, 4, 5, 6)));

    assert(__traits(isSame, heterogeneousLess, adaptiveLessFor!(1.2, "3")));
    assert(__traits(isSame, heterogeneousLess, adaptiveLessFor!(int, 456)));
}


/**
 * Returns $(D true) if $(D items) are the same entities.
 */
template isSame(items...)
{
    static assert(items.length >= 1);

    static if (items.length > 1)
    {
        // TODO: optimize
        static if (is(Entity!(items[0]).ToType == Entity!(items[1]).ToType))
            enum isSame = isSame!(items[1 .. $]);
        else
            enum isSame = false;
    }
    else
    {
        enum isSame = true;
    }
}

unittest
{
    struct S {}
    assert(isSame!(1));
    assert(isSame!(int));
    assert(isSame!(S));
    assert(isSame!(isSame));
}

unittest
{
    struct S
    {
        static extern void fun();
    }

    assert(isSame!(1, 1));
    assert(isSame!("dee", "dee"));
    assert(isSame!(int, int));
    assert(isSame!(S, S));
    assert(isSame!(S.fun, S.fun));
}

unittest
{
    struct U
    {
        static extern void fun();
        static extern void gun();
    }
    struct V {}

    assert(!isSame!(1, 2));
    assert(!isSame!(1, 1.0));
    assert(!isSame!("dee", "Dee"));
    assert(!isSame!(U, V));
    assert(!isSame!(U.fun, U.gun));
}


//----------------------------------------------------------------------------//

/**
 * TODO
 */
template StaticUniq(items...)
{
    static if (items.length > 1)
    {
        static if (isSame!(items[0], items[1]))
            alias             StaticUniq!(items[1 .. $])   StaticUniq;
        else
            alias TypeTuple!( items[0],
                              StaticUniq!(items[1 .. $]) ) StaticUniq;
    }
    else
    {
        alias items StaticUniq;
    }
}

unittest
{
    alias StaticUniq!(       ) uniq___;
    alias StaticUniq!(1      ) uniq1__;
    alias StaticUniq!(1, 2, 3) uniq123;
    alias StaticUniq!(1, 1, 1) uniq111;
    alias StaticUniq!(1, 1, 2) uniq112;
    alias StaticUniq!(1, 2, 2) uniq122;
    alias StaticUniq!(1, 2, 1) uniq121;

    assert(uniq___.length == 0);
    assert(uniq1__.length == 1);
    assert(uniq123.length == 3);
    assert(uniq111.length == 1);
    assert(uniq112.length == 2);
    assert(uniq122.length == 2);
    assert(uniq121.length == 3);

    assert([ uniq1__ ] == [ 1       ]);
    assert([ uniq123 ] == [ 1, 2, 3 ]);
    assert([ uniq111 ] == [ 1       ]);
    assert([ uniq112 ] == [ 1,    2 ]);
    assert([ uniq122 ] == [ 1, 2    ]);
    assert([ uniq121 ] == [ 1, 2, 1 ]);
}

