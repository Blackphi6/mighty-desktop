#!/usr/bin/env python3
"""Convert an HF model to MLX 4-bit. Quantizes on the CPU (the GPU can hit Metal timeouts, e.g. on slow external disks).
usage: convert_model.py <src_dir> <dst_dir>"""
import sys
import mlx.core as mx
mx.set_default_device(mx.cpu)
from mlx_lm.convert import convert
convert(sys.argv[1], mlx_path=sys.argv[2], quantize=True, q_bits=4, q_group_size=64)
