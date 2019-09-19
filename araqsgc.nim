## Shared memory GC for Nim.
## Does not hide anything from you, you remain in complete control.
## (c) 2019 Andreas Rumpf

when not defined(gcDestructors):
  {.error: "Compile with --gc:destructors".}

# Note: Do not compile the -override.*.c files,
# thankfully we don't need them.
{.compile: "mimalloc/alloc-aligned.c".}

{.compile: "mimalloc/alloc.c".}
{.compile: "mimalloc/heap.c".}
{.compile: "mimalloc/init.c".}
{.compile: "mimalloc/memory.c".}
{.compile: "mimalloc/os.c".}
{.compile: "mimalloc/page.c".}
{.compile: "mimalloc/segment.c".}
{.compile: "mimalloc/stats.c".}

# options.c seems silly, find a way to avoid it:
{.compile: "mimalloc/options.c".}

proc mi_zalloc_small(size: int): pointer {.importc, cdecl.}
proc mi_free(p: pointer) {.importc, cdecl.}

type
  MiHeap = object
  VisitHeapCallback = proc (heap: ptr MiHeap, area: pointer, blck: pointer,
                             blockSize: int, arg: pointer): bool {.
                             cdecl, tags: [], raises: [], gcsafe.}

proc mi_heap_visit_blocks(heap: ptr MiHeap, visitAllBlocks: bool;
                          visitor: VisitHeapCallback; arg: pointer): bool {.importc, cdecl.}
proc mi_heap_contains_block(heap: ptr MiHeap; p: pointer): bool {.importc, cdecl.}

proc mi_heap_get_default(): ptr MiHeap {.importc, cdecl.}

type
  RefHeader = object
    epoch: int
    typ: PNimType

  Finalizer {.compilerproc.} = proc (self: pointer) {.nimcall, tags: [], raises: [], gcsafe.}

template `+!`(p: pointer, s: int): pointer =
  cast[pointer](cast[int](p) +% s)

template `-!`(p: pointer, s: int): pointer =
  cast[pointer](cast[int](p) -% s)

template head(p: pointer): ptr RefHeader =
  cast[ptr RefHeader](cast[int](p) -% sizeof(RefHeader))


var
  usedMem*, threshold: int
  epoch: int

proc newObjImpl(typ: PNimType, size: int): pointer {.nimcall, tags: [], raises: [], gcsafe.} =
  let s = size + sizeof(RefHeader)
  result = mi_zalloc_small(s)
  var p = cast[ptr RefHeader](result)
  p.typ = typ
  #p.epoch = epoch
  atomicInc usedMem, s
  result = result +! sizeof(RefHeader)

proc rawDispose(p: pointer) =
  assert p != nil
  let h = head(p)
  assert h != nil
  assert h.typ != nil
  if h.typ.finalizer != nil:
    (cast[Finalizer](h.typ.finalizer))(p)
  atomicDec usedMem, h.typ.base.size + sizeof(RefHeader)
  mi_free(p -! sizeof(RefHeader))

proc shouldCollect*(): bool {.inline.} = (usedMem >= threshold)

proc visitBlock(heap: ptr MiHeap, area: pointer, p: pointer,
                blockSize: int, arg: pointer): bool {.cdecl.} =
  if p != nil:
    let h = head(p)
    if h.epoch < epoch:
      # was only traced in an earlier epoch, which means it's garbage:
      let toFree = cast[ptr seq[pointer]](arg)
      assert p != nil
      toFree[].add(p +! sizeof(RefHeader))
  # do not return early:
  result = true

proc sweep() =
  var toFree = newSeqOfCap[pointer](1_000_000)
  discard mi_heap_visit_blocks(mi_heap_get_default(), true, visitBlock, addr toFree)
  for p in toFree: rawDispose(p)

proc collect*(steps: int) =
  inc epoch
  traverseGlobals()
  traverseThreadLocals()
  sweep()

proc dispose*[T](p: ref T) {.inline.} =
  # free a single object. Also calls ``T``'s destructor before.
  rawDispose(cast[pointer](p))

proc rawDeepDispose(p: pointer) =
  let h = head(p)
  let m = h.typ.marker
  if m != nil:
    m(p, 1)
  rawDispose(p)

proc trace(p: pointer) =
  let h = head(p)
  if h.epoch != epoch:
    assert h.typ != nil
    h.epoch = epoch
    let m = h.typ.marker
    if m != nil: m(p, 0)

proc traverseObjImpl*(p: pointer, op: int) {.nimcall, tags: [], raises: [], gcsafe.} =
  if p != nil:
    if op != 1:
      trace(p)
    else:
      # free stuff
      rawDeepDispose(p)

proc deepDispose*[T](p: ref T) {.inline.} =
  rawDeepDispose(cast[pointer](p))

system.newObjHook = newObjImpl
system.traverseObjHook = traverseObjImpl
