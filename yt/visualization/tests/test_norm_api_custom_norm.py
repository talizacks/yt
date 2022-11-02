from nose.plugins.attrib import attr

from yt.testing import ANSWER_TEST_TAG, fake_random_ds
from yt.utilities.answer_testing.framework import GenericImageTest
from yt.visualization.api import SlicePlot


@attr(ANSWER_TEST_TAG)
def test_sliceplot_custom_norm():
    from matplotlib.colors import TwoSlopeNorm

    ds = fake_random_ds(16)

    def create_image(filename_prefix):
        field = ("gas", "density")
        p = SlicePlot(ds, "z", field)
        p.set_norm(field, norm=(TwoSlopeNorm(vcenter=0, vmin=-0.5, vmax=1)))
        p.save(f"{filename_prefix}")

    test = GenericImageTest(ds, create_image, 12)
    test.prefix = "test_sliceplot_custom_norm"
    test.answer_name = "sliceplot_custom_norm"
    yield test