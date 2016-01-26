"""
Oct container tuned for Particles




"""

#-----------------------------------------------------------------------------
# Copyright (c) 2013, yt Development Team.
#
# Distributed under the terms of the Modified BSD License.
#
# The full license is in the file COPYING.txt, distributed with this software.
#-----------------------------------------------------------------------------

from oct_container cimport OctreeContainer, Oct, OctInfo, ORDER_MAX, \
    SparseOctreeContainer, OctKey, OctAllocationContainer
cimport oct_visitors
from oct_visitors cimport cind
from libc.stdlib cimport malloc, free, qsort
from libc.math cimport floor, ceil, fmod
from fp_utils cimport *
from yt.utilities.lib.geometry_utils cimport bounded_morton#,bounded_morton_mml
cimport numpy as np
import numpy as np
from selection_routines cimport SelectorObject, \
    OctVisitorData, oct_visitor_function, AlwaysSelector
cimport cython
from collections import defaultdict

from particle_deposit cimport gind
from yt.utilities.lib.ewah_bool_array cimport \
    ewah_bool_array
from yt.utilities.lib.ewah_bool_wrap cimport \
    BoolArrayCollection
from libcpp.map cimport map
from libcpp.pair cimport pair
from cython.operator cimport dereference, preincrement

cdef class ParticleOctreeContainer(OctreeContainer):
    cdef Oct** oct_list
    #The starting oct index of each domain
    cdef np.int64_t *dom_offsets
    cdef public int max_level
    #How many particles do we keep befor refining
    cdef public int n_ref

    def allocate_root(self):
        cdef int i, j, k
        cdef Oct *cur
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    cur = self.allocate_oct()
                    self.root_mesh[i][j][k] = cur

    def __dealloc__(self):
        #Call the freemem ops on every ocy
        #of the root mesh recursively
        cdef int i, j, k
        if self.root_mesh == NULL: return
        for i in range(self.nn[0]):
            if self.root_mesh[i] == NULL: continue
            for j in range(self.nn[1]):
                if self.root_mesh[i][j] == NULL: continue
                for k in range(self.nn[2]):
                    if self.root_mesh[i][j][k] == NULL: continue
                    self.visit_free(self.root_mesh[i][j][k])
        free(self.oct_list)
        free(self.dom_offsets)

    cdef void visit_free(self, Oct *o):
        #Free the memory for this oct recursively
        cdef int i, j, k
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_free(o.children[cind(i,j,k)])
        free(o.children)
        free(o)

    def clear_fileind(self):
        cdef int i, j, k
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    self.visit_clear(self.root_mesh[i][j][k])

    cdef void visit_clear(self, Oct *o):
        #Free the memory for this oct recursively
        cdef int i, j, k
        o.file_ind = 0
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_clear(o.children[cind(i,j,k)])

    def __iter__(self):
        #Get the next oct, will traverse domains
        #Note that oct containers can be sorted
        #so that consecutive octs are on the same domain
        cdef int oi
        cdef Oct *o
        for oi in range(self.nocts):
            o = self.oct_list[oi]
            yield (o.file_ind, o.domain_ind, o.domain)

    def allocate_domains(self, domain_counts):
        pass

    def finalize(self, int domain_id = 0):
        #This will sort the octs in the oct list
        #so that domains appear consecutively
        #And then find the oct index/offset for
        #every domain
        cdef int max_level = 0
        self.oct_list = <Oct**> malloc(sizeof(Oct*)*self.nocts)
        cdef np.int64_t i = 0, lpos = 0
        # Note that we now assign them in the same order they will be visited
        # by recursive visitors.
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    self.visit_assign(self.root_mesh[i][j][k], &lpos,
                                      0, &max_level)
        assert(lpos == self.nocts)
        for i in range(self.nocts):
            self.oct_list[i].domain_ind = i
            self.oct_list[i].domain = domain_id
        self.max_level = max_level

    cdef visit_assign(self, Oct *o, np.int64_t *lpos, int level, int *max_level):
        cdef int i, j, k
        self.oct_list[lpos[0]] = o
        lpos[0] += 1
        max_level[0] = imax(max_level[0], level)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_assign(o.children[cind(i,j,k)], lpos,
                                level + 1, max_level)
        return

    cdef np.int64_t get_domain_offset(self, int domain_id):
        return 0

    cdef Oct* allocate_oct(self):
        #Allocate the memory, set to NULL or -1
        #We reserve space for n_ref particles, but keep
        #track of how many are used with np initially 0
        self.nocts += 1
        cdef Oct *my_oct = <Oct*> malloc(sizeof(Oct))
        my_oct.domain = -1
        my_oct.file_ind = 0
        my_oct.domain_ind = self.nocts - 1
        my_oct.children = NULL
        return my_oct

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def add(self, np.ndarray[np.uint64_t, ndim=1] indices,
            np.uint8_t order = ORDER_MAX):
        #Add this particle to the root oct
        #Then if that oct has children, add it to them recursively
        #If the child needs to be refined because of max particles, do so
        cdef np.int64_t no = indices.shape[0], p, index
        cdef int i, level
        cdef int ind[3]
        if self.root_mesh[0][0][0] == NULL: self.allocate_root()
        cdef np.uint64_t *data = <np.uint64_t *> indices.data
        cdef np.uint64_t FLAG = ~(<np.uint64_t>0)
        for p in range(no):
            # We have morton indices, which means we choose left and right by
            # looking at (MAX_ORDER - level) & with the values 1, 2, 4.
            level = 0
            index = indices[p]
            if index == FLAG:
                # This is a marker for the index not being inside the domain
                # we're interested in.
                continue
            # Convert morton index to 3D index of octree root
            for i in range(3):
                ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
            cur = self.root_mesh[ind[0]][ind[1]][ind[2]]
            if cur == NULL:
                raise RuntimeError
            # Continue refining the octree until you reach the level of the
            # morton indexing order. Along the way, use prefix to count
            # previous indices at levels in the octree?
            while (cur.file_ind + 1) > self.n_ref:
                if level >= order: break # Just dump it here.
                level += 1
                for i in range(3):
                    ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
                if cur.children == NULL or \
                   cur.children[cind(ind[0],ind[1],ind[2])] == NULL:
                    cur = self.refine_oct(cur, index, level, order)
                    self.filter_particles(cur, data, p, level, order)
                else:
                    cur = cur.children[cind(ind[0],ind[1],ind[2])]
            # If our n_ref is 1, we are always refining, which means we're an
            # index octree.  In this case, we should store the index for fast
            # lookup later on when we find neighbors and the like.
            if self.n_ref == 1:
                cur.file_ind = index
            else:
                cur.file_ind += 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef Oct *refine_oct(self, Oct *o, np.uint64_t index, int level,
                         np.uint8_t order):
        #Allocate and initialize child octs
        #Attach particles to child octs
        #Remove particles from this oct entirely
        cdef int i, j, k
        cdef int ind[3]
        cdef Oct *noct
        # TODO: This does not need to be changed.
        o.children = <Oct **> malloc(sizeof(Oct *)*8)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    noct = self.allocate_oct()
                    noct.domain = o.domain
                    noct.file_ind = 0
                    o.children[cind(i,j,k)] = noct
        o.file_ind = self.n_ref + 1
        for i in range(3):
            ind[i] = (index >> ((order - level)*3 + (2 - i))) & 1
        noct = o.children[cind(ind[0],ind[1],ind[2])]
        return noct

    cdef void filter_particles(self, Oct *o, np.uint64_t *data, np.int64_t p,
                               int level, np.uint8_t order):
        # Now we look at the last nref particles to decide where they go.
        # If p: Loops over all previous morton indices
        # If n_ref: Loops over n_ref previous morton indices
        cdef int n = imin(p, self.n_ref)
        cdef np.uint64_t *arr = data + imax(p - self.n_ref, 0)
        cdef np.uint64_t prefix1, prefix2
        # Now we figure out our prefix, which is the oct address at this level.
        # As long as we're actually in Morton order, we do not need to worry
        # about *any* of the other children of the oct.
        prefix1 = data[p] >> (order - level)*3
        for i in range(n):
            prefix2 = arr[i] >> (order - level)*3
            if (prefix1 == prefix2):
                o.file_ind += 1 # Says how many morton indices are in this octant?
        #print ind[0], ind[1], ind[2], o.file_ind, level

    def recursively_count(self):
        #Visit every cell, accumulate the # of cells per level
        cdef int i, j, k
        cdef np.int64_t counts[128]
        for i in range(128): counts[i] = 0
        for i in range(self.nn[0]):
            for j in range(self.nn[1]):
                for k in range(self.nn[2]):
                    if self.root_mesh[i][j][k] != NULL:
                        self.visit(self.root_mesh[i][j][k], counts)
        level_counts = {}
        for i in range(128):
            if counts[i] == 0: break
            level_counts[i] = counts[i]
        return level_counts

    cdef visit(self, Oct *o, np.int64_t *counts, level = 0):
        cdef int i, j, k
        counts[level] += 1
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit(o.children[cind(i,j,k)], counts, level + 1)
        return

ctypedef fused anyfloat:
    np.float32_t
    np.float64_t

cdef np.uint64_t ONEBIT=1

cdef class ParticleForest:
    cdef np.float64_t left_edge[3]
    cdef np.float64_t right_edge[3]
    cdef np.float64_t dds[3]
    cdef np.float64_t dds_mi[3]
    cdef np.float64_t idds[3]
    cdef np.int32_t dims[3]
    cdef public np.uint64_t nfiles
    cdef int oref
    cdef public int n_ref
    cdef public ParticleOctreeContainer index_octree
    cdef public np.int32_t index_order
    cdef public object masks
    cdef public object counts
    cdef public object max_count
    cdef public object owners
    cdef public object morton_count
    cdef public object _last_selector
    cdef public object _last_return_values
    cdef public object _cached_octrees
    cdef public object _last_octree_subset
    cdef public object _last_oct_handler
    cdef np.uint32_t *file_markers
    cdef np.uint64_t n_file_markers
    cdef np.uint64_t file_marker_i
    cdef map[np.uint64_t, map[np.int32_t, ewah_bool_array]] bitmasks

    def __init__(self, left_edge, right_edge, dims, nfiles, oref = 1,
                 n_ref = 64, index_order = 7):
        cdef int i
        self._cached_octrees = {}
        self._last_selector = None
        self._last_return_values = None
        self._last_octree_subset = None
        self._last_oct_handler = None
        self.oref = oref
        self.nfiles = nfiles
        self.n_ref = n_ref
        for i in range(3):
            self.left_edge[i] = left_edge[i]
            self.right_edge[i] = right_edge[i]
            self.dims[i] = dims[i]
            self.dds[i] = (right_edge[i] - left_edge[i])/dims[i]
            self.idds[i] = 1.0/self.dds[i] 
            self.dds_mi[i] = (right_edge[i] - left_edge[i]) / (1<<index_order)
        # We use 64-bit masks
        self.masks = []
        self.index_order = index_order
        # This will be an on/off flag for which morton index values are touched
        # by particles.
        self.morton_count = np.zeros(1 << (index_order*3), dtype="uint8")
        # This is the simple way, for now.
        self.masks = np.zeros((1 << (index_order * 3), nfiles), dtype="uint8")

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def add_data_file(self, np.ndarray[anyfloat, ndim=2] pos,
                      np.uint64_t file_id, int filter,
                      np.float64_t rel_buffer):
        # TODO: Replace with the bitarray
        # Initialize
        cdef int i
        cdef np.int64_t p
        cdef np.uint64_t mi
        cdef np.float64_t ppos[3]
        cdef int skip
        cdef np.float64_t LE[3]
        cdef np.float64_t RE[3]
        cdef np.float64_t dds[3]
        cdef np.int32_t order = self.index_order
        # Copy over things for this file (type cast necessary?)
        for i in range(3):
            LE[i] = self.left_edge[i]
            RE[i] = self.right_edge[i]
            dds[i] = self.dds_mi[i]
        cdef np.ndarray[np.uint8_t, ndim=1] mask = self.masks[:,file_id]
        cdef np.ndarray[np.uint8_t, ndim=1] morton_count = self.morton_count
        # Mark index of particles that are in this file
        for p in range(pos.shape[0]): # Over particles
            skip = 0
            for i in range(3): # Over dimensions
                # Skip particles outside the domain
                if pos[p,i] > RE[i] or pos[p,i] < LE[i]:
                    skip = 1
                    break
                ppos[i] = pos[p,i]
            if skip == 1: continue
            #mi = bounded_morton_mml(ppos[0], ppos[1], ppos[2], LE, dds)
            mi = bounded_morton(ppos[0], ppos[1], ppos[2], LE, RE, order)
            morton_count[mi] = mask[mi] = 1
        return

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def secondary_index_data_file(self, np.ndarray[anyfloat, ndim=2] pos,
                      np.ndarray[np.uint8_t, ndim=1] mask,
                      np.uint64_t file_id, int order):
        # Initialize
        cdef np.int64_t p
        cdef np.uint64_t mi, nsub_mi, last_mi, last_submi
        cdef np.float64_t ppos[3]
        cdef int skip
        cdef np.float64_t LE[3]
        cdef np.float64_t box_left[3]
        cdef np.float64_t RE[3]
        cdef np.float64_t box_right[3]
        cdef np.float64_t dds[3]
        cdef np.int64_t total_hits = 0
        # Copy things from structure (type cast)
        for i in range(3):
            LE[i] = self.left_edge[i]
            RE[i] = self.right_edge[i]
            dds[i] = self.dds_mi[i]
        cdef np.ndarray[np.uint64_t, ndim=2] sub_mi
        sub_mi = np.zeros((2, pos.shape[0]), dtype="uint64")
        nsub_mi = 0
        # Loop over positions
        for p in range(pos.shape[0]):
            skip = 0
            for i in range(3):
                # Skip particles outside domain
                if pos[p,i] > RE[i] or pos[p,i] < LE[i]:
                    skip = 1
                    break
                ppos[i] = pos[p,i]
            if skip == 1: continue
            # Find coarse index of particle
            # (Balance between memory cost of storing morton indices & computation time?)
            mi = bounded_morton(ppos[0], ppos[1], ppos[2], LE, RE, self.index_order)
            #mi = bounded_morton_mml(ppos[0], ppos[1], ppos[2], LE, dds)
            # Only look if it's within the mask
            if mask[mi] == 0: continue
            total_hits += 1
            # Compute the bounding box for this index
            # (this is also done inside bounded_morton)
            for i in range(3):
                box_left[i] = (<np.int64_t>((ppos[i] - LE[i])/dds[i])) * dds[i]
                box_right[i] = box_left[i] + dds[i]
            # Determine sub index within cell of primary index
            sub_mi[0, nsub_mi] = mi
            sub_mi[1, nsub_mi] = bounded_morton(ppos[0], ppos[1], ppos[2],
                                                box_left, box_right, order)
            nsub_mi += 1
        # Only subs of particles in the mask
        #print sub_mi.size,
        sub_mi = sub_mi[:,:nsub_mi]
        #print sub_mi.size
        cdef np.ndarray[np.int64_t, ndim=1] ind = np.lexsort(sub_mi)
        last_submi = last_mi = 0
        for i in range(int(nsub_mi)):
            p = ind[i]
            # Make sure its sorted
            if not (sub_mi[1,p] >= last_submi):
                print last_mi, last_submi, sub_mi[0,p], sub_mi[1,p]
                raise RuntimeError
            self.bitmasks[sub_mi[0,p]][file_id].set(sub_mi[1,p])
            if last_mi == sub_mi[0,p]:
                last_submi = sub_mi[1,p]
            else:
                last_submi = 0
            last_mi = sub_mi[0,p]
        return total_hits

    def check(self):
        cdef map[np.uint64_t, map[np.int32_t, ewah_bool_array]].iterator it1
        cdef map[np.int32_t, ewah_bool_array].iterator it2
        cdef pair[np.uint64_t, map[np.int32_t, ewah_bool_array]] p1
        cdef ewah_bool_array arr, arr_any, arr_two, arr_swap
        cdef int nm = 0, nc = 0
        it1 = self.bitmasks.begin()
        while it1 != self.bitmasks.end():
            p1 = dereference(it1)
            it2 = p1.second.begin()
            arr_any.reset()
            arr_two.reset()
            while it2 != p1.second.end():
                arr = dereference(it2).second
                arr_any.logicaland(arr, arr_two)
                arr_any.logicalor(arr, arr_swap)
                arr_any = arr_swap
                preincrement(it2)
            preincrement(it1)
            nm += arr_any.numberOfOnes()
            nc += arr_two.numberOfOnes()
        print "Total of %s / %s collisions (% 3.5f%%)" % (nc, nm, 100.0*float(nc)/nm)

    def finalize(self):
        self.index_octree = ParticleOctreeContainer([1,1,1],
            [self.left_edge[0], self.left_edge[1], self.left_edge[2]],
            [self.right_edge[0], self.right_edge[1], self.right_edge[2]],
            over_refine = 0
        )
        self.index_octree.n_ref = 1
        mi, = np.where(self.morton_count > 0)
        mi = mi.astype("uint64")
        self.index_octree.add(mi, self.index_order)
        self.index_octree.finalize()

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef identify_data_files(self, SelectorObject selector, int ngz = 0):
        cdef map[np.uint64_t, map[np.int32_t, ewah_bool_array]] mask_d
        cdef map[np.uint64_t, map[np.int32_t, ewah_bool_array]].iterator it_mi1
        cdef map[np.int32_t, ewah_bool_array].iterator it_file
        cdef pair[np.uint64_t, map[np.int32_t, ewah_bool_array]] p_mi1_file
        cdef pair[np.int32_t, ewah_bool_array] p_file_mi2
        cdef map[np.uint64_t, ewah_bool_array] mask_s
        cdef BoolArrayCollection cmask_s = BoolArrayCollection()
        mask_s = (<map[np.uint64_t, ewah_bool_array] *> cmask_s.ewah_coll)[0]
        cdef map[np.uint64_t, ewah_bool_array].iterator it_mi1_s
        cdef ewah_bool_array arr1, arr2, arr_and
        cdef np.float64_t pos[3]
        cdef np.float64_t dds[3]
        cdef int j
        cdef np.uint64_t FLAG = ~(<np.uint64_t>0)
        cdef np.uint64_t mi1
        cdef np.int32_t ifile
        cdef np.ndarray[np.uint8_t, ndim=1] file_mask_p
        # Find mask of selected morton indices
        # mask_s = selector.get_morton_mask(self.left_edge,self.right_edge,
        #                                   self.index_order,ngz=ngz)
        for j in range(3):
            pos[j] = np.float64(0.0)
            dds[j] = self.right_edge[j] - self.left_edge[j]
        selector.recursive_morton_mask(0, pos, dds, self.index_order, FLAG, 
                                       cmask_s, ngz=ngz)
        # Compare with mask of particles
        file_mask_p = np.zeros(self.nfiles, dtype="uint8")
        it_mi1_d = mask_d.begin()
        while it_mi1_d != mask_d.end():
            p_mi1_file = dereference(it_mi1_d)
            mi1 = p_mi1_file.first
            it_mi1_s = mask_s.find(mi1)
            # Only continue if mi1 selected
            if (it_mi1_s != mask_s.end()):
                arr1 = dereference(it_mi1_s).second
                it_file = p_mi1_file.second.begin()
                while it_file != p_mi1_file.second.end():
                    ifile = dereference(it_file).first
                    # Only continue if file not already selected
                    if not file_mask_p[ifile]:
                        arr_and.reset()
                        arr2 = dereference(it_file).second
                        arr1.logicaland(arr2,arr_and)
                        if arr_and.numberOfOnes() > 0:
                            file_mask_p[ifile] = 1
                    # Increment file
                    preincrement(it_file)
            # Increment mi1
            preincrement(it_mi1_d)
        return np.where(file_mask_p)[0]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def construct_forest(self, np.uint64_t file_id, SelectorObject selector,
                         io_handler, data_files, data_file_info = None):
        if file_id in self._cached_octrees:
            iv = self._cached_octrees[file_id]
            rv = ParticleForestOctreeContainer.load_octree(iv)
            return rv
        cdef np.ndarray[np.uint8_t, ndim=3] omask
        if data_file_info is None:
            data_file_info = self.identify_data_files(selector) 
        _, _, omask, _ = data_file_info
        # cdef np.float64_t LE[3], RE[3]
        cdef np.uint64_t total_pcount = 0
        cdef np.uint64_t fcheck, fmask
        cdef np.ndarray[np.uint64_t, ndim=3] counts
        cdef np.ndarray[np.uint64_t, ndim=3] mask 
        cdef np.ndarray[np.int32_t, ndim=3] forest_nodes
        forest_nodes = np.zeros((self.dims[0], self.dims[1], self.dims[2]),
            dtype="int32") - 1
        counts = self.counts
        cdef int i, j, k, n, nm, ii
        nm = len(self.masks)
        cdef np.uint64_t **masks = <np.uint64_t **> malloc(
            sizeof(np.uint64_t *) * nm)
        for n in range(nm):
            mask = self.masks[n]
            masks[n] = <np.uint64_t *> mask.data
        cdef int file_mask_id = <int> (file_id / 64.0)
        cdef np.uint64_t index, file_mask = (ONEBIT << (file_id % 64))
        cdef np.uint8_t *file_ids = <np.uint8_t*> malloc(
            sizeof(np.uint8_t) * self.nfiles)
        for i in range(self.nfiles):
            file_ids[i] = 0
        index = -1
        cdef int dims[3]
        for i in range(3):
            dims[i] = self.dims[i]
        cdef np.ndarray[np.int32_t, ndim=3] owners = self.owners
        cdef int nroot = 0
        for i in range(self.dims[0]):
            for j in range(self.dims[1]):
                for k in range(self.dims[2]):
                    index += 1
                    ii = gind(i, j, k, dims)
                    if owners[i,j,k] != file_id or \
                       omask[i,j,k] == 0 or \
                        (masks[file_mask_id][ii] & file_mask) == 0:
                        continue
                    forest_nodes[i,j,k] = nroot
                    nroot += 1
                    total_pcount += counts[i,j,k]
                    # multiple will be 0 for use this zone, 1 for skip it
                    # We get this one, so we'll continue ...
                    for n in range(nm):
                        # First we count
                        fmask = masks[n][ii]
                        for fcheck in range(64):
                            if ((fmask >> fcheck) & ONEBIT) == ONEBIT:
                                # First to arrive gets it
                                file_ids[fcheck + n * 64] = 1
        # Now we can actually create a sparse octree.
        cdef ParticleForestOctreeContainer octree
        octree = ParticleForestOctreeContainer(
            (self.dims[0], self.dims[1], self.dims[2]),
            (self.left_edge[0], self.left_edge[1], self.left_edge[2]),
            (self.right_edge[0], self.right_edge[1], self.right_edge[2]),
            nroot, self.oref)
        octree.n_ref = self.n_ref
        octree.allocate_domains()
        cdef np.ndarray[np.uint64_t, ndim=1] morton_ind, morton_view
        morton_ind = np.empty(total_pcount, dtype="uint64")
        cdef np.int32_t *particle_index = <np.int32_t *> malloc(
            sizeof(np.int32_t) * nroot)
        cdef np.int32_t *particle_count = <np.int32_t *> malloc(
            sizeof(np.int32_t) * nroot)
        total_pcount = 0
        for i in range(self.dims[0]):
            for j in range(self.dims[1]):
                for k in range(self.dims[2]):
                    if forest_nodes[i,j,k] == -1: continue
                    particle_index[forest_nodes[i,j,k]] = total_pcount
                    particle_count[forest_nodes[i,j,k]] = counts[i,j,k]
                    total_pcount += counts[i,j,k]
        # Okay, now just to filter based on our mask.
        cdef int ind[3]
        cdef int arri
        cdef np.ndarray pos
        cdef np.ndarray[np.float32_t, ndim=2] pos32
        cdef np.ndarray[np.float64_t, ndim=2] pos64
        cdef np.float64_t ppos[3]
        cdef np.float64_t DLE[3]
        cdef np.float64_t DRE[3]
        cdef int bitsize = 0
        for i in range(self.nfiles):
            if file_ids[i] == 0: continue
            # We now get our particle positions
            for pos in io_handler._yield_coordinates(data_files[i]):
                pos32 = pos64 = None
                bitsize = 0
                if pos.dtype == np.float32:
                    pos32 = pos
                    bitsize = 32
                elif pos.dtype == np.float64:
                    pos64 = pos
                    bitsize = 64
                else:
                    raise RuntimeError
                for j in range(pos.shape[0]):
                    # First we get our cell index.
                    for k in range(3):
                        if bitsize == 32:
                            ppos[k] = pos32[j,k]
                        else:
                            ppos[k] = pos64[j,k]
                        ind[k] = <int> ((ppos[k] - self.left_edge[k])*self.idds[k])
                    arri = forest_nodes[ind[0], ind[1], ind[2]]
                    if arri == -1: continue
                    # Now we have decided it's worth filtering, so let's toss
                    # it in.
                    for i in range(3):
                        DLE[i] = self.left_edge[i] + self.dds[i]*ind[i]
                        DRE[i] = DLE[i] + self.dds[i]
                    morton_ind[particle_index[arri]] = bounded_morton(
                        ppos[0], ppos[1], ppos[2], DLE, DRE, ORDER_MAX)
                    particle_index[arri] += 1
                    octree.next_root(1, ind)
        cdef int start, end = 0
        # We should really allocate a 3-by nroot array
        for i in range(self.dims[0]):
            for j in range(self.dims[1]):
                for k in range(self.dims[2]):
                    arri = forest_nodes[i,j,k]
                    if arri == -1: continue
                    start = end
                    end += particle_count[arri]
                    morton_view = morton_ind[start:end]
                    morton_view.sort()
                    octree.add(morton_view, i, j, k, owners[i,j,k])
        octree.finalize()
        free(particle_index)
        free(particle_count)
        free(file_ids)
        free(masks)
        self._cached_octrees[file_id] = octree.save_octree()
        return octree
        
cdef class ParticleForestOctreeContainer(SparseOctreeContainer):
    cdef Oct** oct_list
    cdef public int max_level
    cdef public int n_ref
    cdef int loaded # Loaded with load_octree?
    def __init__(self, domain_dimensions, domain_left_edge, domain_right_edge,
                 int num_root, over_refine = 1):
        super(ParticleForestOctreeContainer, self).__init__(
            domain_dimensions, domain_left_edge, domain_right_edge,
            over_refine)
        self.loaded = 0
        self.fill_func = oct_visitors.fill_file_indices_oind

        # Now the overrides
        self.max_root = num_root
        self.root_nodes = <OctKey*> malloc(sizeof(OctKey) * num_root)
        for i in range(num_root):
            self.root_nodes[i].key = -1
            self.root_nodes[i].node = NULL

    def allocate_domains(self, counts = None):
        if counts is None:
            counts = [self.max_root]
        OctreeContainer.allocate_domains(self, counts)

    def finalize(self):
        #This will sort the octs in the oct list
        #so that domains appear consecutively
        #And then find the oct index/offset for
        #every domain
        cdef int max_level = 0
        self.oct_list = <Oct**> malloc(sizeof(Oct*)*self.nocts)
        cdef np.int64_t i, lpos = 0
        # Note that we now assign them in the same order they will be visited
        # by recursive visitors.
        for i in range(self.num_root):
            self.visit_assign(self.root_nodes[i].node, &lpos, 0, &max_level)
        assert(lpos == self.nocts)
        for i in range(self.nocts):
            self.oct_list[i].domain_ind = i
            # We don't assign this ... it helps with selecting later.
            #self.oct_list[i].domain = 0
            self.oct_list[i].file_ind = -1
        self.max_level = max_level

    cdef visit_assign(self, Oct *o, np.int64_t *lpos, int level, int *max_level):
        cdef int i, j, k
        self.oct_list[lpos[0]] = o
        lpos[0] += 1
        max_level[0] = imax(max_level[0], level)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_assign(o.children[cind(i,j,k)], lpos,
                                level + 1, max_level)
        return

    cdef Oct* allocate_oct(self):
        #Allocate the memory, set to NULL or -1
        #We reserve space for n_ref particles, but keep
        #track of how many are used with np initially 0
        self.nocts += 1
        cdef Oct *my_oct = <Oct*> malloc(sizeof(Oct))
        my_oct.domain = -1
        my_oct.file_ind = 0
        my_oct.domain_ind = self.nocts - 1
        my_oct.children = NULL
        return my_oct

    def __dealloc__(self):
        #Call the freemem ops on every ocy
        #of the root mesh recursively
        cdef int i
        if self.root_nodes== NULL: return
        if self.cont != NULL and self.cont.next == NULL: return
        if self.loaded == 0:
            for i in range(self.max_root):
                if self.root_nodes[i].node == NULL: continue
                self.visit_free(&self.root_nodes.node[i], 0)
            free(self.cont)
            self.cont = self.root_nodes = NULL
        free(self.oct_list)
        self.oct_list = NULL

    cdef void visit_free(self, Oct *o, int free_this):
        #Free the memory for this oct recursively
        cdef int i, j, k
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    if o.children != NULL \
                       and o.children[cind(i,j,k)] != NULL:
                        self.visit_free(o.children[cind(i,j,k)], 1)
        if o.children != NULL:
            free(o.children)
        if free_this == 1:
            free(o)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def add(self, np.ndarray[np.uint64_t, ndim=1] indices,
             int root_i, int root_j, int root_k, int domain_id = -1):
        #Add this particle to the root oct
        #Then if that oct has children, add it to them recursively
        #If the child needs to be refined because of max particles, do so
        cdef Oct *cur
        cdef Oct *root = NULL
        cdef np.int64_t no = indices.shape[0], p, index
        cdef int i, level
        cdef int ind[3]
        ind[0] = root_i
        ind[1] = root_j
        ind[2] = root_k
        self.get_root(ind, &root)
        if root == NULL:
            raise RuntimeError
        root.domain = domain_id
        cdef np.uint64_t *data = <np.uint64_t *> indices.data
        # Note what we're doing here: we have decided the root will always be
        # zero, since we're in a forest of octrees, where the root_mesh node is
        # the level 0.  This means our morton indices should be made with
        # respect to that, which means we need to keep a few different arrays
        # of them.
        for i in range(3):
            ind[i] = 0
        for p in range(no):
            # We have morton indices, which means we choose left and right by
            # looking at (MAX_ORDER - level) & with the values 1, 2, 4.
            level = 0
            index = indices[p]
            cur = root
            while (cur.file_ind + 1) > self.n_ref:
                if level >= ORDER_MAX: break # Just dump it here.
                level += 1
                for i in range(3):
                    ind[i] = (index >> ((ORDER_MAX - level)*3 + (2 - i))) & 1
                if cur.children == NULL or \
                   cur.children[cind(ind[0],ind[1],ind[2])] == NULL:
                    cur = self.refine_oct(cur, index, level)
                    self.filter_particles(cur, data, p, level)
                else:
                    cur = cur.children[cind(ind[0],ind[1],ind[2])]
            cur.file_ind += 1

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef Oct *refine_oct(self, Oct *o, np.uint64_t index, int level):
        #Allocate and initialize child octs
        #Attach particles to child octs
        #Remove particles from this oct entirely
        cdef int i, j, k
        cdef int ind[3]
        cdef Oct *noct
        # TODO: This does not need to be changed.
        o.children = <Oct **> malloc(sizeof(Oct *)*8)
        for i in range(2):
            for j in range(2):
                for k in range(2):
                    noct = self.allocate_oct()
                    noct.domain = o.domain
                    noct.file_ind = 0
                    o.children[cind(i,j,k)] = noct
        o.file_ind = self.n_ref + 1
        for i in range(3):
            ind[i] = (index >> ((ORDER_MAX - level)*3 + (2 - i))) & 1
        noct = o.children[cind(ind[0],ind[1],ind[2])]
        return noct

    cdef void filter_particles(self, Oct *o, np.uint64_t *data, np.int64_t p,
                               int level):
        # Now we look at the last nref particles to decide where they go.
        cdef int n = imin(p, self.n_ref)
        cdef np.uint64_t *arr = data + imax(p - self.n_ref, 0)
        # Now we figure out our prefix, which is the oct address at this level.
        # As long as we're actually in Morton order, we do not need to worry
        # about *any* of the other children of the oct.
        prefix1 = data[p] >> (ORDER_MAX - level)*3
        for i in range(n):
            prefix2 = arr[i] >> (ORDER_MAX - level)*3
            if (prefix1 == prefix2):
                o.file_ind += 1
        #print ind[0], ind[1], ind[2], o.file_ind, level

    @classmethod
    def load_octree(cls, header):
        cdef ParticleForestOctreeContainer obj = cls(
                header['dims'], header['left_edge'],
                header['right_edge'], header['num_root'],
                over_refine = header['over_refine'])
        cdef np.uint64_t i, j
        cdef np.int64_t i64ind[3]
        cdef int ind[3]
        cdef np.ndarray[np.uint8_t, ndim=1] ref_mask, packed_mask
        obj.loaded = 1
        packed_mask = header['octree']
        ref_mask = np.zeros(header['nocts'], 'uint8')
        i = j = 0
        while i * 8 + j < ref_mask.size:
            ref_mask[i * 8 + j] = ((packed_mask[i] >> j) & 1)
            j += 1
            if j == 8:
                j = 0
                i += 1
        # NOTE: We do not allow domain/file indices to be specified.
        cdef SelectorObject selector = AlwaysSelector(None)
        cdef OctVisitorData data
        obj.setup_data(&data, -1)
        data.global_index = -1
        data.level = 0
        data.oref = 0
        data.nz = 1
        assert(ref_mask.shape[0] / float(data.nz) ==
            <int>(ref_mask.shape[0]/float(data.nz)))
        obj.allocate_domains([obj.max_root, ref_mask.size - obj.max_root])
        cdef np.ndarray[np.uint64_t, ndim=1] keys = header['keys']
        cdef np.int64_t domain_id = header['domain_id']
        cdef OctAllocationContainer *cur 
        cur = obj.domains[1]
        for i in range(obj.max_root):
            obj.key_to_ipos(keys[i], i64ind)
            for j in range(3):
                ind[j] = i64ind[j]
            obj.next_root(1, ind)
        cdef np.float64_t dds[3]
        # This dds is the oct-width
        for i in range(3):
            dds[i] = (obj.DRE[i] - obj.DLE[i]) / obj.nn[i]
        # Pos is the center of the octs
        cdef void *p[4]
        cdef np.int64_t nfinest = 0
        p[0] = ref_mask.data
        p[1] = <void *> cur.my_octs
        p[2] = <void *> &cur.n_assigned
        p[3] = <void *> &nfinest
        data.array = p
        obj.visit_all_octs(selector, oct_visitors.load_octree, &data, 1)
        obj.nocts = data.index
        obj.finalize()
        for j in range(2):
            cur = obj.domains[j]
            for i in range(cur.n):
                cur.my_octs[i].domain = domain_id
        if obj.nocts * data.nz != ref_mask.size:
            raise KeyError(ref_mask.size, obj.nocts, obj.oref,
                obj.partial_coverage)
        return obj

    def save_octree(self):
        header = dict(dims = (self.nn[0], self.nn[1], self.nn[2]),
                      left_edge = (self.DLE[0], self.DLE[1], self.DLE[2]),
                      right_edge = (self.DRE[0], self.DRE[1], self.DRE[2]),
                      over_refine = self.oref, num_root = self.num_root)
        cdef np.uint64_t i, j
        cdef SelectorObject selector = AlwaysSelector(None)
        # domain_id = -1 here, because we want *every* oct
        cdef OctVisitorData data
        self.setup_data(&data, -1)
        data.oref = 0
        data.nz = 1
        cdef np.ndarray[np.uint8_t, ndim=1] ref_mask
        cdef np.ndarray[np.uint8_t, ndim=1] packed_mask
        cdef np.ndarray[np.uint64_t, ndim=1] keys
        ref_mask = np.zeros(self.nocts * data.nz, dtype="uint8") - 1
        keys = np.zeros(self.num_root, "uint64")
        for i in range(self.num_root):
            keys[i] = self.root_nodes[i].key
        cdef void *p[1]
        p[0] = ref_mask.data
        data.array = p
        # Enforce partial_coverage here
        self.visit_all_octs(selector, oct_visitors.store_octree, &data, 1)
        # Now let's bitpack; we'll un-bitpack later.
        packed_mask = np.zeros(ceil(self.nocts * data.nz/8.0), dtype="uint8")
        i = j = 0
        while i * 8 + j < self.nocts * data.nz:
            packed_mask[i] |= (ref_mask[i * 8 + j] << j)
            j += 1
            if j == 8:
                j = 0
                i += 1
        header['octree'] = packed_mask
        header['nocts'] = self.nocts
        header['keys'] = keys
        header['domain_id'] = self.oct_list[0].domain
        return header

