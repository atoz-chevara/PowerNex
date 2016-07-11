module Memory.Heap;

import Memory.Paging;
import Data.Linker;
import Data.Address;
import IO.Log;
import CPU.IDT;
import Data.Register;
import Task.Mutex.SpinLockMutex;
import Data.BitField;

enum ulong MAGIC = 0xDEAD_BEEF_DEAD_C0DE;

private struct MemoryHeader {
	ulong magic;
	MemoryHeader* prev;
	MemoryHeader* next;
	private ulong data;
	mixin(Bitfield!(data, "isAllocated", 1, "size", 63));
}

class Heap {
public:
	this(Paging paging, MapMode mode, VirtAddress startAddr) {
		this.paging = paging;
		this.mode = mode;
		this.startAddr = this.endAddr = startAddr;
		this.root = null;
		this.end = null;

		addNewPage();
		root = end; // 'end' will be the latest allocated page
	}

	~this() {
		for (VirtAddress start = startAddr; start < endAddr; start += 0x1000)
			paging.UnmapAndFree(start);
	}

	void* Alloc(ulong size) {
		mutex.Lock;
		if (!size)
			return null;

		MemoryHeader* freeChunk = root;
		size += MinimalChunkSize - (size % MinimalChunkSize); // Good alignment maybe?

		while (freeChunk && (freeChunk.isAllocated || freeChunk.size < size))
			freeChunk = freeChunk.next;

		while (!freeChunk || freeChunk.size < size) { // We are currently at the end chunk
			if (!addNewPage()) { // This will work just because there is combine in addNewPage, which will increase the current chunks size
				mutex.Unlock;
				return null;
			}
			freeChunk = end; // Don't expected that freeChunk is valid, addNewPage runs combine
		}

		split(freeChunk, size); // Make sure that we don't give away to much memory

		freeChunk.isAllocated = true;
		mutex.Unlock;
		return (VirtAddress(freeChunk) + MemoryHeader.sizeof).Ptr;
	}

	void Free(void* addr) {
		mutex.Lock;
		if (!addr)
			return;
		MemoryHeader* hdr = cast(MemoryHeader*)(VirtAddress(addr) - MemoryHeader.sizeof).Ptr;
		hdr.isAllocated = false;

		combine(hdr);

		mutex.Unlock;
	}

	void* Realloc(void* addr, ulong size) {
		void* newMem = Alloc(size);
		mutex.Lock;
		if (addr) {
			MemoryHeader* old = cast(MemoryHeader*)(VirtAddress(addr) - MemoryHeader.sizeof).Ptr;
			ubyte* src = cast(ubyte*)addr;
			ubyte* dest = cast(ubyte*)newMem;
			for (ulong i = 0; i < old.size && i < size; i++)
				dest[i] = src[i];

			mutex.Unlock;
			Free(addr);
		}
		return newMem;
	}

	void PrintLayout() {
		for (MemoryHeader* start = root; start; start = start.next) {
			log.Info("address: ", start, "\tmagic: ", cast(void*)start.magic, "\thasPrev: ", !!start.prev,
					"\thasNext: ", !!start.next, "\tisAllocated: ", !!start.isAllocated, "\tsize: ", start.size,
					"\tnext: ", start.next);

			if (start.magic != MAGIC)
				log.Fatal("====MAGIC IS WRONG====");
		}

		log.Info("\n\n");
	}

private:
	enum MinimalChunkSize = 32; /// Without header

	SpinLockMutex mutex;
	Paging paging;
	MapMode mode;
	MemoryHeader* root; /// Stores the first MemoryHeader
	MemoryHeader* end; /// Stores the last MemoryHeader
	VirtAddress startAddr; /// The start address of all the allocated data
	VirtAddress endAddr; /// The end address of all the allocated data

	/// Map and add a new page to the list
	bool addNewPage() {
		MemoryHeader* oldEnd = end;

		if (paging.MapFreeMemory(endAddr, mode).Int == 0)
			return false;
		end = cast(MemoryHeader*)endAddr.Ptr;
		*end = MemoryHeader.init;
		end.magic = MAGIC;
		endAddr += 0x1000;

		end.prev = oldEnd;
		if (oldEnd)
			oldEnd.next = end;

		end.size = 0x1000 - MemoryHeader.sizeof;
		end.next = null;
		end.isAllocated = false;

		combine(end); // Combine with other nodes if possible
		return true;
	}

	/// 'chunk' should not be expected to be valid after this
	MemoryHeader* combine(MemoryHeader* chunk) {
		MemoryHeader* freeChunk = chunk;
		ulong sizeGain = 0;

		// Combine backwards
		while (freeChunk.prev && !freeChunk.prev.isAllocated) {
			sizeGain += freeChunk.size + MemoryHeader.sizeof;
			freeChunk = freeChunk.prev;
		}

		if (freeChunk != chunk) {
			freeChunk.size = freeChunk.size + sizeGain;
			freeChunk.next = chunk.next;
			if (freeChunk.next)
				freeChunk.next.prev = freeChunk;

			*chunk = MemoryHeader.init; // Set the old header to zero
			chunk.magic = MAGIC;

			chunk = freeChunk;
		}

		// Combine forwards
		sizeGain = 0;
		while (freeChunk.next && !freeChunk.next.isAllocated) {
			freeChunk = freeChunk.next;
			sizeGain += freeChunk.size + MemoryHeader.sizeof;
		}

		if (freeChunk != chunk) {
			chunk.size = chunk.size + sizeGain;
			chunk.next = freeChunk.next;
			if (chunk.next)
				chunk.next.prev = chunk;
		}

		if (!chunk.next)
			end = chunk;

		return chunk;
	}

	/// It will only split if it can, chunk will always be approved to be allocated after the call this this function.
	void split(MemoryHeader* chunk, ulong size) {
		if (chunk.size >= size + ( /* The smallest chunk size */ MemoryHeader.sizeof + MinimalChunkSize)) {
			MemoryHeader* newChunk = cast(MemoryHeader*)(VirtAddress(chunk) + MemoryHeader.sizeof + size).Ptr;
			newChunk.magic = MAGIC;
			newChunk.prev = chunk;
			newChunk.next = chunk.next;
			chunk.next = newChunk;
			newChunk.isAllocated = false;
			newChunk.size = chunk.size - size - MemoryHeader.sizeof;
			chunk.size = size;

			if (!newChunk.next)
				end = newChunk;
		}
	}
}

/// Get the kernel heap object
Heap GetKernelHeap() {
	import Data.Util : InplaceClass;

	__gshared ubyte[__traits(classInstanceSize, Heap)] data;
	__gshared Heap kernelHeap;

	if (!kernelHeap) {
		kernelHeap = InplaceClass!Heap(data, GetKernelPaging, MapMode.DefaultUser, Linker.KernelEnd);
		IDT.Register(InterruptType.PageFault, &onPageFault);
	}
	return kernelHeap;
}

private void onPageFault(Registers* regs) {
	import Data.TextBuffer : scr = GetBootTTY;
	import IO.Log;

	with (regs) {
		import Data.Color;

		scr.Foreground = Color(255, 0, 0);
		scr.Writeln("===> PAGE FAULT");
		scr.Writeln("IRQ = ", IntNumber, " | RIP = ", cast(void*)RIP);
		scr.Writeln("RAX = ", cast(void*)RAX, " | RBX = ", cast(void*)RBX);
		scr.Writeln("RCX = ", cast(void*)RCX, " | RDX = ", cast(void*)RDX);
		scr.Writeln("RDI = ", cast(void*)RDI, " | RSI = ", cast(void*)RSI);
		scr.Writeln("RSP = ", cast(void*)RSP, " | RBP = ", cast(void*)RBP);
		scr.Writeln(" R8 = ", cast(void*)R8, "  |  R9 = ", cast(void*)R9);
		scr.Writeln("R10 = ", cast(void*)R10, " | R11 = ", cast(void*)R11);
		scr.Writeln("R12 = ", cast(void*)R12, " | R13 = ", cast(void*)R13);
		scr.Writeln("R14 = ", cast(void*)R14, " | R15 = ", cast(void*)R15);
		scr.Writeln(" CS = ", cast(void*)CS, "  |  SS = ", cast(void*)SS);
		scr.Writeln(" CR2 = ", cast(void*)CR2);
		scr.Writeln("Flags: ", cast(void*)Flags);
		scr.Writeln("Errorcode: ", cast(void*)ErrorCode, " (", ErrorCode & 0x1 ? " Present" : " NotPresent",
				ErrorCode & 0x2 ? " Write" : " Read", ErrorCode & 0x4 ? " UserMode" : " KernelMode", ErrorCode & 0x8
				? " ReservedWrite" : "", ErrorCode & 0x2 ? " InstructionFetch" : "", " )");

		log.Fatal("===> PAGE FAULT", "\n", "IRQ = ", IntNumber, " | RIP = ", cast(void*)RIP, "\n", "RAX = ",
				cast(void*)RAX, " | RBX = ", cast(void*)RBX, "\n", "RCX = ", cast(void*)RCX, " | RDX = ",
				cast(void*)RDX, "\n", "RDI = ", cast(void*)RDI, " | RSI = ", cast(void*)RSI, "\n", "RSP = ",
				cast(void*)RSP, " | RBP = ", cast(void*)RBP, "\n", " R8 = ", cast(void*)R8, "  |  R9 = ",
				cast(void*)R9, "\n", "R10 = ", cast(void*)R10, " | R11 = ", cast(void*)R11, "\n", "R12 = ",
				cast(void*)R12, " | R13 = ", cast(void*)R13, "\n", "R14 = ", cast(void*)R14, " | R15 = ",
				cast(void*)R15, "\n", " CS = ", cast(void*)CS, "  |  SS = ", cast(void*)SS, "\n", " CR2 = ",
				cast(void*)CR2, "\n", "Flags: ", cast(void*)Flags, "\n", "Errorcode: ", cast(void*)ErrorCode, " (",
				ErrorCode & 0x1 ? " Present" : " NotPresent", ErrorCode & 0x2 ? " Write" : " Read", ErrorCode & 0x4
				? " UserMode" : " KernelMode", ErrorCode & 0x8 ? " ReservedWrite" : "", ErrorCode & 0x2 ? " InstructionFetch" : "", " )");
	}
}
