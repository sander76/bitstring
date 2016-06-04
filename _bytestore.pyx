#!python
#cython: language_level=2, profile=True

import copy
import mmap
import os

class MmapByteArray(bytearray):
    """Looks like a bytearray, but from an mmap.

    Not part of public interface.
    """

    # cdef int filelength, byteoffset, bytelength
    # cdef public object filemap

    def __init__(self, source, bytelength=None, byteoffset=None):
        self.sourcename = source.name
        source.seek(0, os.SEEK_END)
        self.filelength = source.tell()
        if byteoffset is None:
            byteoffset = 0
        if bytelength is None:
            bytelength = self.filelength - byteoffset
        self.byteoffset = byteoffset
        self.bytelength = bytelength
        self.filemap = mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ)

    def __getitem__(self, key):
        try:
            start = key.start
            stop = key.stop
        except AttributeError:
            try:
                assert 0 <= key < self.bytelength
                return ord(self.filemap[key + self.byteoffset])
            except TypeError:
                # for Python 3
                return self.filemap[key + self.byteoffset]
        else:
            if start is None:
                start = 0
            if stop is None:
                stop = self.bytelength
            assert key.step is None
            assert 0 <= start < self.bytelength
            assert 0 <= stop <= self.bytelength
            s = slice(start + self.byteoffset, stop + self.byteoffset)
            return bytearray(self.filemap.__getitem__(s))

    def __len__(self):
        return self.bytelength


cdef class ByteStore:
    """Stores raw bytes together with a bit offset and length.

    Used internally - not part of public interface.
    """

    def __init__(self, data, bitlength=None, offset=None, immutable=False):
        """data is either a bytearray or a MmapByteArray"""
        self._rawarray = data
        if offset is None:
            offset = 0
        if bitlength is None:
            bitlength = 8 * len(data) - offset
        self.offset = offset
        self.bitlength = bitlength
        self.immutable = immutable

    cpdef bint getbit(self, int pos):
        cdef int byte, bit
        assert 0 <= pos < self.bitlength
        byte, bit = divmod(self.offset + pos, 8)
        return bool(self._rawarray[byte] & (128 >> bit))

    cpdef int getbyte(self, int pos):
        """Direct access to byte data."""
        return self._rawarray[pos]

    def getbyteslice(self, start, end):
        """Direct access to byte data."""
        c = self._rawarray[start:end]
        return c

    @property
    def bytelength(self):
        cdef int sb, eb
        if not self.bitlength:
            return 0
        sb = self.offset // 8
        eb = (self.offset + self.bitlength - 1) // 8
        return eb - sb + 1

    def __copy__(self):
        return ByteStore(self._rawarray[:], self.bitlength, self.offset)

    cpdef _appendstore(self, ByteStore store):
        """Join another store on to the end of this one."""
        cdef int joinval
        if not store.bitlength:
            return
        # Set new array offset to the number of bits in the final byte of current array.
        store = offsetcopy(store, (self.offset + self.bitlength) % 8)
        if store.offset:
            # first do the byte with the join.
            joinval = (self._rawarray.pop() & (255 ^ (255 >> store.offset)) |
                       (store.getbyte(0) & (255 >> store.offset)))
            self._rawarray.append(joinval)
            self._rawarray.extend(store._rawarray[1:])
        else:
            self._rawarray.extend(store._rawarray)
        self.bitlength += store.bitlength

    cpdef _prependstore(self, ByteStore store):
        """Join another store on to the start of this one."""
        if not store.bitlength:
            return
            # Set the offset of copy of store so that it's final byte
        # ends in a position that matches the offset of self,
        # then join self on to the end of it.
        store = offsetcopy(store, (self.offset - store.bitlength) % 8)
        assert (store.offset + store.bitlength) % 8 == self.offset % 8
        bit_offset = self.offset % 8
        if bit_offset:
            # first do the byte with the join.
            store.setbyte(-1, (store.getbyte(-1) & (255 ^ (255 >> bit_offset)) | \
                               (self._rawarray[self.byteoffset] & (255 >> bit_offset))))
            store._rawarray.extend(self._rawarray[self.byteoffset + 1: self.byteoffset + self.bytelength])
        else:
            store._rawarray.extend(self._rawarray[self.byteoffset: self.byteoffset + self.bytelength])
        self._rawarray = store._rawarray
        self.offset = store.offset
        self.bitlength += store.bitlength

    @property
    def byteoffset(self):
        return self.offset // 8

    @property
    def rawbytes(self):
        return self._rawarray

    cpdef setbit(self, int pos):
        assert 0 <= pos < self.bitlength
        assert self.immutable is False
        byte, bit = divmod(self.offset + pos, 8)
        self._rawarray[byte] |= (128 >> bit)

    cpdef unsetbit(self, int pos):
        assert 0 <= pos < self.bitlength
        assert self.immutable is False
        byte, bit = divmod(self.offset + pos, 8)
        self._rawarray[byte] &= ~(128 >> bit)

    cpdef invertbit(self, int pos):
        assert 0 <= pos < self.bitlength
        assert self.immutable is False
        byte, bit = divmod(self.offset + pos, 8)
        self._rawarray[byte] ^= (128 >> bit)

    cpdef setbyte(self, int pos, int value):
        assert self.immutable is False
        self._rawarray[pos] = value

    def setbyteslice(self, start, end, value):
        self._rawarray[start:end] = value


cpdef ByteStore offsetcopy(ByteStore s, int newoffset):
    """Return a copy of a ByteStore with the newoffset.

    Not part of public interface.
    """
    cdef ByteStore new_s
    cdef int shiftleft, x, bits_in_last_byte, shiftright

    assert 0 <= newoffset < 8
    if not s.bitlength:
        return copy.copy(s)
    else:
        if newoffset == s.offset % 8:
            return ByteStore(s.getbyteslice(s.byteoffset, s.byteoffset + s.bytelength), s.bitlength, newoffset)
        newdata = []
        d = s._rawarray
        assert newoffset != s.offset % 8
        if newoffset < s.offset % 8:
            # We need to shift everything left
            shiftleft = s.offset % 8 - newoffset
            # First deal with everything except for the final byte
            for x in range(s.byteoffset, s.byteoffset + s.bytelength - 1):
                newdata.append(((d[x] << shiftleft) & 0xff) +\
                               (d[x + 1] >> (8 - shiftleft)))
            bits_in_last_byte = (s.offset + s.bitlength) % 8
            if not bits_in_last_byte:
                bits_in_last_byte = 8
            if bits_in_last_byte > shiftleft:
                newdata.append((d[s.byteoffset + s.bytelength - 1] << shiftleft) & 0xff)
        else: # newoffset > s._offset % 8
            shiftright = newoffset - s.offset % 8
            newdata.append(s.getbyte(0) >> shiftright)
            for x in range(s.byteoffset + 1, s.byteoffset + s.bytelength):
                newdata.append(((d[x - 1] << (8 - shiftright)) & 0xff) +\
                               (d[x] >> shiftright))
            bits_in_last_byte = (s.offset + s.bitlength) % 8
            if not bits_in_last_byte:
                bits_in_last_byte = 8
            if bits_in_last_byte + shiftright > 8:
                newdata.append((d[s.byteoffset + s.bytelength - 1] << (8 - shiftright)) & 0xff)
        new_s = ByteStore(bytearray(newdata), s.bitlength, newoffset)
        assert new_s.offset == newoffset
        return new_s

cpdef bint equal(ByteStore a, ByteStore b):
    """Return True if ByteStores a == b.

    Not part of public interface.
    """
    cdef int a_bitlength, b_bitlength, a_bitoff, b_bitoff, a_byteoffset, b_byteoffset, a_bytelength, b_bytelength
    cdef int bits_spare_in_last_byte, a_val, b_val, shift, final_b_bits, final_a_bits
    # We want to return False for inequality as soon as possible, which
    # means we get lots of special cases.
    # First the easy one - compare lengths:
    a_bitlength = a.bitlength
    b_bitlength = b.bitlength
    if a_bitlength != b_bitlength:
        return False
    if not a_bitlength:
        assert b_bitlength == 0
        return True
    # Make 'a' the one with the smaller offset
    if (a.offset % 8) > (b.offset % 8):
        a, b = b, a
    # and create some aliases
    a_bitoff = a.offset % 8
    b_bitoff = b.offset % 8
    a_byteoffset = a.byteoffset
    b_byteoffset = b.byteoffset
    a_bytelength = a.bytelength
    b_bytelength = b.bytelength
    da = a._rawarray
    db = b._rawarray

    # If they are pointing to the same data, they must be equal
    if da is db and a.offset == b.offset:
        return True

    if a_bitoff == b_bitoff:
        bits_spare_in_last_byte = 8 - (a_bitoff + a_bitlength) % 8
        if bits_spare_in_last_byte == 8:
            bits_spare_in_last_byte = 0
        # Special case for a, b contained in a single byte
        if a_bytelength == 1:
            a_val = ((da[a_byteoffset] << a_bitoff) & 0xff) >> (8 - a_bitlength)
            b_val = ((db[b_byteoffset] << b_bitoff) & 0xff) >> (8 - b_bitlength)
            return a_val == b_val
        # Otherwise check first byte
        if da[a_byteoffset] & (0xff >> a_bitoff) != db[b_byteoffset] & (0xff >> b_bitoff):
            return False
        # then everything up to the last
        b_a_offset = b_byteoffset - a_byteoffset
        for x in range(1 + a_byteoffset, a_byteoffset + a_bytelength - 1):
            if da[x] != db[b_a_offset + x]:
                return False
        # and finally the last byte
        return (da[a_byteoffset + a_bytelength - 1] >> bits_spare_in_last_byte ==
                db[b_byteoffset + b_bytelength - 1] >> bits_spare_in_last_byte)

    assert a_bitoff != b_bitoff
    # This is how much we need to shift a to the right to compare with b:
    shift = b_bitoff - a_bitoff
    # Special case for b only one byte long
    if b_bytelength == 1:
        assert a_bytelength == 1
        a_val = ((da[a_byteoffset] << a_bitoff) & 0xff) >> (8 - a_bitlength)
        b_val = ((db[b_byteoffset] << b_bitoff) & 0xff) >> (8 - b_bitlength)
        return a_val == b_val
    # Special case for a only one byte long
    if a_bytelength == 1:
        assert b_bytelength == 2
        a_val = ((da[a_byteoffset] << a_bitoff) & 0xff) >> (8 - a_bitlength)
        b_val = ((db[b_byteoffset] << 8) + db[b_byteoffset + 1]) << b_bitoff
        b_val &= 0xffff
        b_val >>= 16 - b_bitlength
        return a_val == b_val

    # Compare first byte of b with bits from first byte of a
    if (da[a_byteoffset] & (0xff >> a_bitoff)) >> shift != db[b_byteoffset] & (0xff >> b_bitoff):
        return False
    # Now compare every full byte of b with bits from 2 bytes of a
    for x in range(1, b_bytelength - 1):
        # Construct byte from 2 bytes in a to compare to byte in b
        b_val = db[b_byteoffset + x]
        a_val = ((da[a_byteoffset + x - 1] << 8) + da[a_byteoffset + x]) >> shift
        a_val &= 0xff
        if a_val != b_val:
            return False

    # Now check bits in final byte of b
    final_b_bits = (b.offset + b_bitlength) % 8
    if not final_b_bits:
        final_b_bits = 8
    b_val = db[b_byteoffset + b_bytelength - 1] >> (8 - final_b_bits)
    final_a_bits = (a.offset + a_bitlength) % 8
    if not final_a_bits:
        final_a_bits = 8
    if b.bytelength > a_bytelength:
        assert b_bytelength == a_bytelength + 1
        a_val = da[a_byteoffset + a_bytelength - 1] >> (8 - final_a_bits)
        a_val &= 0xff >> (8 - final_b_bits)
        return a_val == b_val
    assert a_bytelength == b_bytelength
    a_val = da[a_byteoffset + a_bytelength - 2] << 8
    a_val += da[a_byteoffset + a_bytelength - 1]
    a_val >>= (8 - final_a_bits)
    a_val &= 0xff >> (8 - final_b_bits)
    return a_val == b_val