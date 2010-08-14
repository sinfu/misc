
import std.typetuple : TypeTuple;


template Sort(items...)
{
    alias MergeSort!(HeteroLess, items).result Sort;
}

pragma(msg, Sort!( 6, 2, 4, 1, 3, 5));  // (1,2,3,4,5,6)
pragma(msg, Sort!(int, string, char));  // (char, int, string)
pragma(msg, Sort!("abcdef", int, 42));  // (int, 42, "abcdef")


//----------------------------------------------------------------------------//
// Merge Sort
//----------------------------------------------------------------------------//

template MergeSort(alias less, items...)
    if (items.length < 2)
{
    alias items result;
}

template MergeSort(alias less, items...)
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
                    alias TypeTuple!(sortA[0], Merge!(sortA[1 .. $]).With!(sortB        )) With;
                else
                    alias TypeTuple!(sortB[0], Merge!(sortA        ).With!(sortB[1 .. $])) With;
            }
        }
    }

    alias Merge!(MergeSort!(less, items[  0 .. $/2]).result)
          .With!(MergeSort!(less, items[$/2 .. $  ]).result) result;
}


//----------------------------------------------------------------------------//
// Insertion Sort
//----------------------------------------------------------------------------//

template InsertionSort(alias less, items...)
    if (items.length < 2)
{
    alias items result;
}

template InsertionSort(alias less, items...)
    if (items.length >= 2)
{
    template Insert()
    {
        alias TypeTuple!(items[0]) Insert;
    }

    template Insert(list...)
    {
        static assert(list.length > 0);

        static if (less!(items[0], list[0]))
            alias TypeTuple!(items[0], list) Insert;
        else
            alias TypeTuple!(list[0], Insert!(list[1 .. $])) Insert;
    }

    alias Insert!(InsertionSort!(less, items[1 .. $]).result) result;
}


//----------------------------------------------------------------------------//
// Heterogeneous Comparator
//----------------------------------------------------------------------------//

template HeteroLess(items...)
{
    static assert(items.length >= 2);

    static if (items.length > 2)
        enum bool HeteroLess = HeteroLess!(items[0 .. 2]) &&
                               HeteroLess!(items[1 .. $]);
    else
        enum bool HeteroLess = (Id!(items[0]) < Id!(items[1]));
}

template Id(entities...)
{
    enum string Id = Entity!(entities).ToType.mangleof;
}

template Entity(entities...)
{
    struct ToType {}
}

