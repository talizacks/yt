import glob

import numpy as np

from yt.data_objects.static_output import ParticleFile, validate_index_order
from yt.frontends.ytdata.data_structures import SavedDataset
from yt.funcs import parse_h5_attr
from yt.geometry.particle_geometry_handler import ParticleIndex
from yt.utilities.on_demand_imports import _h5py as h5py

from .fields import HaloCatalogFieldInfo

class HaloCatalogParticleIndex(ParticleIndex):
    def _setup_filenames(self):
        template = self.dataset.filename_template
        ndoms = self.dataset.file_count
        cls = self.dataset._file_class
        if ndoms > 1:
            self.data_files = [
                cls(self.dataset, self.io, template % {"num": i}, i, range=None)
                for i in range(ndoms)
            ]
        else:
            self.data_files = [
                cls(
                    self.dataset,
                    self.io,
                    self.dataset.parameter_filename,
                    0,
                    range=None,
                )
            ]
        self.total_particles = sum(
            sum(d.total_particles.values()) for d in self.data_files
        )


class HaloCatalogFile(ParticleFile):
    def __init__(self, ds, io, filename, file_id, range):
        super(HaloCatalogFile, self).__init__(ds, io, filename, file_id, range)

    def _read_particle_positions(self, ptype, f=None):
        raise NotImplementedError

    def _get_particle_positions(self, ptype, f=None):
        pcount = self.total_particles[ptype]
        if pcount == 0:
            return None

        # Correct for periodicity.
        dle = self.ds.domain_left_edge.to("code_length").v
        dw = self.ds.domain_width.to("code_length").v
        pos = self._read_particle_positions(ptype, f=f)
        si, ei = self.start, self.end
        if None not in (si, ei):
            pos = pos[si:ei]

        np.subtract(pos, dle, out=pos)
        np.mod(pos, dw, out=pos)
        np.add(pos, dle, out=pos)

        return pos


class HaloCatalogHDF5File(HaloCatalogFile):
    def __init__(self, ds, io, filename, file_id, range):
        with h5py.File(filename, mode="r") as f:
            self.header = dict(
                (field, parse_h5_attr(f, field)) for field in f.attrs.keys()
            )
        super(HaloCatalogHDF5File, self).__init__(ds, io, filename, file_id, range)

    def _read_particle_positions(self, ptype, f=None):
        """
        Read all particle positions in this file.
        """

        if f is None:
            close = True
            f = h5py.File(self.filename, mode="r")
        else:
            close = False

        pcount = self.header["num_halos"]
        pos = np.empty((pcount, 3), dtype="float64")
        for i, ax in enumerate("xyz"):
            pos[:, i] = f["particle_position_%s" % ax][()]

        if close:
            f.close()

        return pos


class HaloCatalogDataset(SavedDataset):
    _index_class = ParticleIndex
    _file_class = HaloCatalogHDF5File
    _field_info_class = HaloCatalogFieldInfo
    _suffix = ".h5"
    _con_attrs = ("cosmological_simulation",
                  "current_time", "current_redshift",
                  "hubble_constant", "omega_matter", "omega_lambda",
                  "domain_left_edge", "domain_right_edge")

    def __init__(
        self,
        filename,
        dataset_type="halocatalog_hdf5",
        index_order=None,
        units_override=None,
        unit_system="cgs",
    ):
        self.index_order = validate_index_order(index_order)
        super(HaloCatalogDataset, self).__init__(
            filename,
            dataset_type,
            units_override=units_override,
            unit_system=unit_system,
        )

    def _parse_parameter_file(self):
        self.refine_by = 2
        self.dimensionality = 3
        self.domain_dimensions = np.ones(self.dimensionality, "int32")
        self.periodicity = (True, True, True)
        prefix = ".".join(self.parameter_filename.rsplit(".", 2)[:-2])
        self.filename_template = "%s.%%(num)s%s" % (prefix, self._suffix)
        self.file_count = len(glob.glob(prefix + "*" + self._suffix))
        self.particle_types = "halos"
        self.particle_types_raw = "halos"
        super(HaloCatalogDataset, self)._parse_parameter_file()

    @classmethod
    def _is_valid(self, *args, **kwargs):
        if not args[0].endswith(".h5"):
            return False
        with h5py.File(args[0], mode="r") as f:
            if (
                "data_type" in f.attrs
                and parse_h5_attr(f, "data_type") == "halo_catalog"
            ):
                return True
        return False
