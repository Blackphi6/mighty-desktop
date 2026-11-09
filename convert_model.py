#!/usr/bin/env python3
"""HF のモデルを MLX 4bit に変換する。CPU で量子化する(GPU だと遅い外付けディスク等で Metal タイムアウトになることがあるため)。
usage: convert_model.py <src_dir> <dst_dir>"""
import sys
import mlx.core as mx
mx.set_default_device(mx.cpu)
from mlx_lm.convert import convert
convert(sys.argv[1], mlx_path=sys.argv[2], quantize=True, q_bits=4, q_group_size=64)
