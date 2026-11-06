#!/usr/bin/env python3
"""HEVC wire helpers for the fake phone (--codec hevc): NAL types, parameter
sets, IDR/CRA and access-unit cuts. No TLS, no ffmpeg, no Mac:

    python3 tools/fakephone/test_hevc.py
"""

import contextlib
import io
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fakephone  # noqa: E402
import proto  # noqa: E402


def annexb(*units):
    out = b""
    for unit in units:
        out += b"\x00\x00\x00\x01" + bytes(unit)
    return out


VPS = [0x40, 0x01, 0x0C, 0x01]
SPS = [0x42, 0x01, 0x01, 0x01]
PPS = [0x44, 0x01, 0xC0]
IDR = [0x26, 0x01, 0xAF]
CRA = [0x2A, 0x01, 0xAF]
DELTA = [0x02, 0x01, 0xD0]


class HevcNalTest(unittest.TestCase):
    def test_hevc_types_use_their_own_field(self):
        blob = b"\x00\x00\x01" + bytes(SPS)
        self.assertEqual(proto.nal_type(blob, proto.CODEC_HEVC), 33)
        self.assertEqual(proto.nal_type(blob, proto.CODEC_H264), 2)
        self.assertEqual(proto.nal_type(b"\x00\x00\x01" + bytes(IDR),
                                        proto.CODEC_HEVC), 19)
        self.assertEqual(proto.nal_type(b"\x00\x00\x01" + bytes(CRA),
                                        proto.CODEC_HEVC), 21)

    def test_the_parameter_sets_come_out_in_order(self):
        blob = annexb(VPS, SPS, PPS)
        sets = proto.extract_hevc_parameter_sets(proto.split_nals(blob))
        self.assertIsNotNone(sets)
        self.assertIn(bytes(VPS), sets)
        self.assertIn(bytes(SPS), sets)
        self.assertIn(bytes(PPS), sets)
        self.assertLess(sets.index(bytes(VPS)), sets.index(bytes(SPS)))
        self.assertLess(sets.index(bytes(SPS)), sets.index(bytes(PPS)))
        self.assertIsNone(proto.extract_hevc_parameter_sets(
            proto.split_nals(annexb(VPS, SPS))))

    def test_only_19_and_20_are_idrs(self):
        self.assertTrue(proto.is_idr(proto.split_nals(annexb(VPS, SPS, PPS, IDR)),
                                     proto.CODEC_HEVC))
        self.assertTrue(proto.is_idr(proto.split_nals(annexb([0x28, 0x01])),
                                     proto.CODEC_HEVC), "IDR_N_LP is 20")
        self.assertFalse(proto.is_idr(proto.split_nals(annexb(VPS, SPS, PPS, CRA)),
                                      proto.CODEC_HEVC), "a CRA is not an IDR")
        self.assertFalse(proto.is_idr(proto.split_nals(annexb(DELTA)),
                                      proto.CODEC_HEVC))

    def test_a_cra_does_not_cut_the_next_access_unit(self):
        # A CRA is a VCL slice (21 is below 32): it starts a picture, and the
        # next parameter sets are the boundary.
        data = annexb(VPS, SPS, PPS, CRA, VPS, SPS, PPS, DELTA)
        splitter = proto.AccessUnitSplitter(proto.CODEC_HEVC)
        units = splitter.feed(data) + splitter.flush()
        self.assertEqual(len(units), 2)
        self.assertIn(bytes(CRA), units[0])
        self.assertIn(bytes(DELTA), units[1])

    def test_two_pictures_without_a_delimiter_are_split(self):
        # libx265 emits no AUD between frames: the next picture's first slice
        # flag (the MSB after the two-byte NAL header) is the boundary.
        data = annexb(VPS, SPS, PPS, IDR, DELTA)
        splitter = proto.AccessUnitSplitter(proto.CODEC_HEVC)
        units = splitter.feed(data) + splitter.flush()
        self.assertEqual(len(units), 2)
        self.assertIn(bytes(IDR), units[0])
        self.assertIn(bytes(DELTA), units[1])

    def test_the_splitter_accepts_the_stream_token(self):
        # WindowStream holds "hevc"/"avc"; a token must select the HEVC rules
        # too, or frames pile up unseen (the C5 HEVC run's first failure).
        data = annexb(VPS, SPS, PPS, IDR, DELTA)
        splitter = proto.AccessUnitSplitter("hevc")
        units = splitter.feed(data) + splitter.flush()
        self.assertEqual(len(units), 2)
        self.assertEqual(proto.AccessUnitSplitter("avc").codec, proto.CODEC_H264)

    def test_the_splitter_cuts_at_the_hevc_aud(self):
        data = annexb(VPS, SPS, PPS, IDR, [0x46, 0x01, 0x50], DELTA)
        splitter = proto.AccessUnitSplitter(proto.CODEC_HEVC)
        units = splitter.feed(data) + splitter.flush()
        self.assertEqual(len(units), 2)
        self.assertIn(bytes(IDR), units[0])
        self.assertIn(bytes(DELTA), units[1])

    def test_the_avc_splitter_is_unchanged(self):
        avc_idr = [0x65, 0x88]
        avc_delta = [0x41, 0x9A]
        data = annexb([0x67, 1], [0x68, 2], avc_idr, avc_delta)
        splitter = proto.AccessUnitSplitter()
        units = splitter.feed(data) + splitter.flush()
        self.assertEqual(len(units), 1, "only one AVC access unit: no AUD, one slice")
        self.assertIn(bytes(avc_delta), units[0])


class CodecChoiceTest(unittest.TestCase):
    def phone(self, codec, hello):
        phone = types.SimpleNamespace(args=types.SimpleNamespace(codec=codec),
                                      _session=types.SimpleNamespace(hello=hello))
        phone.mac_codecs = lambda: fakephone.FakePhone.mac_codecs(phone)
        return phone

    def test_hevc_needs_the_macs_hello(self):
        choice = fakephone.FakePhone.stream_codec
        fallback = self.phone("hevc", {"codecs": ["avc"]})
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(choice(fallback), "avc")
        self.assertIn("codec=hevc unsupported: mac", err.getvalue())
        self.assertEqual(choice(self.phone("hevc", {"codecs": ["avc", "hevc"]})),
                         "hevc")
        # An older Mac's hello has no list at all: AVC only, one line.
        self.assertEqual(choice(self.phone("hevc", {})), "avc")

    def test_the_default_arm_is_avc(self):
        choice = fakephone.FakePhone.stream_codec
        self.assertEqual(choice(self.phone("avc", {"codecs": ["avc", "hevc"]})),
                         "avc")


if __name__ == "__main__":
    unittest.main()
