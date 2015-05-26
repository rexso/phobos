module std.experimental.allocator.allocator_list;

import std.experimental.allocator.common;
import std.experimental.allocator.null_allocator;
import std.experimental.allocator.gc_allocator;
version(unittest) import std.stdio;

// Turn this on for debugging
// debug = allocator_list;

/**

Given $(D make(size_t n)) as a function that returns fresh allocators capable of
allocating at least $(D n) bytes, and $(D BookkeepingAllocator) as a
supplemental allocator for bookkeeping, $(D AllocatorList) creates an allocator
that lazily creates as many allocators are needed for satisfying client
allocation requests.

An embedded list builds a most-recently-used strategy: the most recent
allocators used in calls to either $(D allocate), $(D owns) (successful calls
only), or $(D deallocate) are tried for new allocations in order of their most
recent use. Thus, although core operations take in theory $(BIGOH k) time for
$(D k) allocators in current use, in many workloads the factor is sublinear.
Details of the actual strategy may change in future releases.

$(D AllocatorList) is primarily intended for coarse-grained handling of
allocators, i.e. the number of allocators in the list is expected to be
relatively small compared to the number of allocations handled by each
allocator. However, the per-allocator overhead is small so using $(D
AllocatorList) with a large number of allocators should be satisfactory as long
as the most-recently-used strategy is fast enough for the application.

$(D AllocatorList) makes an effort to return allocated memory back when no
longer used. It does so by destroying empty allocators. However, in order to
avoid thrashing (excessive creation/destruction of allocators under certain use
patterns), it keeps unused allocators for a while.

Params:
make = alias for a function that returns new allocators on a need basis. $(D
make(n)) should return an allocator able to allocate at least $(D n) bytes.
Usually the capacity of allocators should be much larger than $(D n) such that
an allocator can be used for many subsequent allocations. $(D n) is passed only
to ensure the minimum necessary for the next allocation.

BookkeepingAllocator = Allocator used for storing bookkeeping data. The size of
bookkeeping data is proportional to the number of allocators. If $(D
BookkeepingAllocator) is $(D NullAllocator), then $(D AllocatorList) is
"ouroboros-style", i.e. it keeps the bookkeeping data in memory obtained from
the allocators themselves. Note that for ouroboros-style management, the size
$(D n) passed to $(D make) will be occasionally different from the size
requested by client code.
*/
struct AllocatorList(alias make, BookkeepingAllocator = GCAllocator)
{
    import std.traits : hasMember;
    import std.conv : emplace;
    import std.algorithm : min, move;
    import std.experimental.allocator.stats_collector : StatsCollector, Options;

    private enum ouroboros = is(BookkeepingAllocator == NullAllocator);

    /// Alias for $(D typeof(make)).
    alias Allocator = typeof(make(1));
    // Allocator used internally
    private alias SAllocator = StatsCollector!(Allocator, Options.bytesUsed);

    private static struct Node
    {
        // Allocator in this node
        SAllocator a;
        Node* next;

        @disable this(this);

        // Is this node unused?
        void setUnused() { next = &this; }
        bool unused() const { return next == &this; }

        // Just forward everything to the allocator
        alias a this;
    }

    /**
    If $(D BookkeepingAllocator) is not $(D NullAllocator), $(D bkalloc) is
    defined and accessible.
    */
    // State is stored in an array, but it has a list threaded through it by
    // means of "nextIdx".
    // state {
    static if (!ouroboros)
    {
        static if (stateSize!BookkeepingAllocator) BookkeepingAllocator bkalloc;
        else alias bkalloc = BookkeepingAllocator.it;
    }
    private Node[] allocators;
    private Node* root;
    // }

    static if (hasMember!(Allocator, "deallocateAll")
        && hasMember!(Allocator, "owns"))
    ~this()
    {
        deallocateAll;
    }

    /**
    The alignment offered.
    */
    enum uint alignment = Allocator.alignment;

    /**
    Allocate a block of size $(D s). First tries to allocate from the existing
    list of already-created allocators. If neither can satisfy the request,
    creates a new allocator by calling $(D make(s)) and delegates the request
    to it. However, if the allocation fresh off a newly created allocator
    fails, subsequent calls to $(D allocate) will not cause more calls to $(D
    make).
    */
    void[] allocate(size_t s)
    {
        for (auto p = &root, n = *p; n; p = &n.next, n = *p)
        {
            auto result = n.allocate(s);
            if (result.length != s) continue;
            assert(owns(result));
            // Bring to front if not already
            if (root != n)
            {
                *p = n.next;
                n.next = root;
                root = n;
                return result;
            }
        }
        // Can't allocate from the current pool. Check if we just added a new
        // allocator, in that case it won't do any good to add yet another.
        if (root && root.empty)
        {
            // no can do
            return null;
        }
        // Add a new allocator
        if (auto a = addAllocator(s))
        {
            auto result = a.allocate(s);
            assert(owns(result) || !result.ptr);
            return result;
        }
        return null;
    }

    private void moveAllocators(void[] newPlace)
    {
        assert(newPlace.ptr.alignedAt(Node.alignof));
        assert(newPlace.length % Node.sizeof == 0);
        auto newAllocators = cast(Node[]) newPlace;
        assert(allocators.length <= newAllocators.length);

        // Move allocators
        foreach (i, ref e; allocators)
        {
            if (e.unused)
            {
                newAllocators[i].setUnused;
                continue;
            }
            import core.stdc.string : memcpy;
            memcpy(&newAllocators[i].a, &e.a, e.a.sizeof);
            if (e.next)
            {
                newAllocators[i].next = newAllocators.ptr
                    + (e.next - allocators.ptr);
            }
            else
            {
                newAllocators[i].next = null;
            }
        }

        // Mark the unused portion as unused
        foreach (i; allocators.length .. newAllocators.length)
        {
            newAllocators[i].setUnused;
        }
        auto toFree = allocators;

        // Change state {
        root = newAllocators.ptr + (root - allocators.ptr);
        allocators = newAllocators;
        // }

        // Free the olden buffer
        static if (ouroboros)
        {
            static if (hasMember!(Allocator, "deallocate")
                    && hasMember!(Allocator, "owns"))
                deallocate(toFree);
        }
        else
        {
            bkalloc.deallocate(toFree);
        }
    }

    static if (ouroboros)
    private Node* addAllocator(size_t atLeastBytes)
    {
        void[] t = allocators;
        static if (hasMember!(Allocator, "expand")
            && hasMember!(Allocator, "owns"))
        {
            bool expanded = t && this.expand(t, Node.sizeof);
        }
        else
        {
            enum expanded = false;
        }
        if (expanded)
        {
            assert(t.length % Node.sizeof == 0);
            assert(t.ptr.alignedAt(Node.alignof));
            allocators = cast(Node[]) t;
            allocators[$ - 1].setUnused;
            auto newAlloc = SAllocator(make(atLeastBytes));
            import core.stdc.string;
            memcpy(&allocators[$ - 1].a, &newAlloc, newAlloc.sizeof);
            emplace(&newAlloc);
        }
        else
        {
            immutable toAlloc = (allocators.length + 1) * Node.sizeof
                + atLeastBytes + 128;
            auto newAlloc = SAllocator(make(toAlloc));
            auto newPlace = newAlloc.allocate(
                (allocators.length + 1) * Node.sizeof);
            if (!newPlace) return null;
            moveAllocators(newPlace);
            import core.stdc.string : memcpy;
            memcpy(&allocators[$ - 1].a, &newAlloc, newAlloc.sizeof);
            emplace(&newAlloc);
            assert(allocators[$ - 1].owns(allocators));
        }
        // Insert as new root
        if (root != &allocators[$ - 1])
        {
            allocators[$ - 1].next = root;
            root = &allocators[$ - 1];
        }
        else
        {
            // This is the first one
            root.next = null;
        }
        assert(!root.unused);
        return root;
    }

    static if (!ouroboros)
    private Node* addAllocator(size_t atLeastBytes)
    {
        void[] t = allocators;
        if (bkalloc.expand(t, Node.sizeof))
        {
            assert(t.length % Node.sizeof == 0);
            assert(t.ptr.alignedAt(Node.alignof));
            allocators = cast(Node[]) t;
            allocators[$ - 1].setUnused;
        }
        else
        {
            // Could not expand, create a new block
            t = bkalloc.allocate((allocators.length + 1) * Node.sizeof);
            assert(t.length % Node.sizeof == 0);
            if (!t.ptr) return null;
            moveAllocators(t);
        }
        assert(allocators[$ - 1].unused);
        auto newAlloc = SAllocator(make(atLeastBytes));
        import core.stdc.string : memcpy;
        memcpy(&allocators[$ - 1].a, &newAlloc, newAlloc.sizeof);
        emplace(&newAlloc);
        // Creation succeeded, insert as root
        allocators[$ - 1].next = root;
        root = &allocators[$ - 1];
        return root;
    }

    /**
    Defined only if $(D Allocator) defines $(D owns). Tries each allocator in
    turn, in most-recently-used order. If the owner is found, it is moved to
    the front of the list.
    */
    static if (hasMember!(Allocator, "owns"))
    bool owns(void[] b)
    {
        for (auto p = &root, n = *p; n; p = &n.next, n = *p)
        {
            if (!n.owns(b)) continue;
            // Move the owner to front, speculating it'll be used
            if (n != root)
            {
                *p = n.next;
                n.next = root;
                root = n;
            }
            return true;
        }
        return false;
    }

    /**
    Defined only if $(D Allocator.expand) is defined. Finds the owner of $(D b)
    and calls $(D expand) for it. The owner is not brought to the head of the
    list.
    */
    static if (hasMember!(Allocator, "expand")
        && hasMember!(Allocator, "owns"))
    bool expand(ref void[] b, size_t delta)
    {
        if (!b.ptr)
        {
            b = allocate(delta);
            return b.length == delta;
        }
        for (auto p = &root, n = *p; n; p = &n.next, n = *p)
        {
            if (n.owns(b)) return n.expand(b, delta);
        }
        return false;
    }

    /**
    Defined only if $(D Allocator.reallocate) is defined. Finds the owner of
    $(D b) and calls $(D reallocate) for it. If that fails, calls the global
    $(D reallocate), which allocates a new block and moves memory.
    */
    static if (hasMember!(Allocator, "reallocate"))
    bool reallocate(ref void[] b, size_t s)
    {
        // First attempt to reallocate within the existing node
        if (!b.ptr)
        {
            b = allocate(s);
            return b.length == s;
        }
        for (auto p = &root, n = *p; n; p = &n.next, n = *p)
        {
            if (n.owns(b)) return n.reallocate(b, s);
        }
        // Failed, but we may find new memory in a new node.
        return .reallocate(this, b, s);
    }

    /**
     Defined if $(D Allocator.deallocate) and $(D Allocator.owns) are defined.
    */
    static if (hasMember!(Allocator, "deallocate")
        && hasMember!(Allocator, "owns"))
    void deallocate(void[] b)
    {
        if (!b.ptr) return;
        assert(allocators.length);
        assert(owns(b));
        for (auto p = &root, n = *p; ; p = &n.next, n = *p)
        {
            assert(n);
            if (!n.owns(b)) continue;
            n.deallocate(b);
            // Bring to front
            if (n != root)
            {
                *p = n.next;
                n.next = root;
                root = n;
            }
            if (!n.empty) return;
            break;
        }
        // Hmmm... should we return this allocator back to the wild? Let's
        // decide if there are TWO empty allocators we can release ONE. This
        // is to avoid thrashing.
        // Note that loop starts from the second element.
        for (auto p = &root.next, n = *p; n; p = &n.next, n = *p)
        {
            if (n.unused || !n.empty) continue;
            // Used and empty baby, nuke it!
            n.a.destroy;
            *p = n.next;
            n.setUnused;
            break;
        }
    }

    /**
    Defined only if $(D Allocator.owns) and $(D Allocator.deallocateAll) are
    defined.
    */
    static if (ouroboros && hasMember!(Allocator, "deallocateAll")
        && hasMember!(Allocator, "owns"))
    void deallocateAll()
    {
        Node* special;
        foreach (ref n; allocators)
        {
            if (n.unused) continue;
            if (n.owns(allocators))
            {
                special = &n;
                continue;
            }
            n.a.deallocateAll;
            n.a.destroy;
        }
        assert(special || !allocators.ptr);
        if (special)
        {
            special.deallocate(allocators);
        }
        allocators = null;
        root = null;
    }

    static if (!ouroboros && hasMember!(Allocator, "deallocateAll")
        && hasMember!(Allocator, "owns"))
    void deallocateAll()
    {
        foreach (ref n; allocators)
        {
            if (n.unused) continue;
            n.a.deallocateAll;
            n.a.destroy;
        }
        bkalloc.deallocate(allocators);
        allocators = null;
        root = null;
    }

    /// Returns $(D true) iff no allocators are currently active.
    bool empty() const
    {
        return !allocators.length;
    }
}

///
version(Posix) unittest
{
    import std.algorithm : max;
    import std.experimental.allocator.region;
    import std.experimental.allocator.mmap_allocator;
    import std.experimental.allocator.segregator;
    import std.experimental.allocator.free_list;

    // Ouroboros allocator list based upon 4MB regions, fetched directly from
    // mmap. All memory is released upon destruction.
    alias A1 = AllocatorList!((n) => Region!MmapAllocator(max(n, 1024 * 4096)),
        NullAllocator);

    // Allocator list based upon 4MB regions, fetched from the garbage
    // collector. All memory is released upon destruction.
    alias A2 = AllocatorList!((n) => Region!GCAllocator(max(n, 1024 * 4096)));

    // Ouroboros allocator list based upon 4MB regions, fetched from the garbage
    // collector. Memory is left to the collector.
    alias A3 = AllocatorList!(
        (n) => Region!NullAllocator(new void[max(n, 1024 * 4096)]),
        NullAllocator);

    // Allocator list that creates one freelist for all objects
    alias A4 =
        Segregator!(
            64, AllocatorList!(
                (n) => ContiguousFreeList!(NullAllocator, 0, 64)(
                    GCAllocator.it.allocate(4096))),
            GCAllocator);

    A4 a;
    auto small = a.allocate(64);
    assert(small);
    //a.deallocate(small);
    //auto b1 = a.allocate(1024 * 8192);
    //assert(b1 !is null); // still works due to overdimensioning
    //b1 = a.allocate(1024 * 10);
    //assert(b1.length == 1024 * 10);
}

unittest
{
    // Create an allocator based upon 4MB regions, fetched from the GC heap.
    import std.algorithm : max;
    import std.experimental.allocator.region;
    AllocatorList!((n) => Region!GCAllocator(new void[max(n, 1024 * 4096)]),
        NullAllocator) a;
    auto b1 = a.allocate(1024 * 8192);
    assert(b1 !is null); // still works due to overdimensioning
    auto b2 = a.allocate(1024 * 10);
    assert(b2.length == 1024 * 10);
    a.deallocateAll();
}

unittest
{
    // Create an allocator based upon 4MB regions, fetched from the GC heap.
    import std.algorithm : max;
    import std.experimental.allocator.region;
    AllocatorList!((n) => Region!()(new void[max(n, 1024 * 4096)])) a;
    auto b1 = a.allocate(1024 * 8192);
    assert(b1 !is null); // still works due to overdimensioning
    b1 = a.allocate(1024 * 10);
    assert(b1.length == 1024 * 10);
    a.deallocateAll();
}

unittest
{
    import std.algorithm : max;
    import std.experimental.allocator.region;
    AllocatorList!((n) => Region!()(new void[max(n, 1024 * 4096)])) a;
    auto b1 = a.allocate(1024 * 8192);
    assert(b1 !is null);
    b1 = a.allocate(1024 * 10);
    assert(b1.length == 1024 * 10);
    auto b2 = a.allocate(1024 * 4095);
    a.deallocateAll();
    assert(a.empty);
}
