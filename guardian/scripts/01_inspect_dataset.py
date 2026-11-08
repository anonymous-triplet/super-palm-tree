"""
Guardian Layer — Dataset Inspection (read-only)
File: scripts/01_inspect_dataset.py

Usage:
    python scripts/01_inspect_dataset.py path/to/your/file

This script NEVER modifies the input file. It only reads and prints.
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd


def load_any(path: Path) -> pd.DataFrame:
    """Load a dataset from CSV / Excel / JSON / Parquet based on extension."""
    ext = path.suffix.lower()
    if ext in (".csv", ".txt"):
        # Try comma first; if the DataFrame has 1 column, retry with auto-detect.
        df = pd.read_csv(path)
        if df.shape[1] == 1:
            df = pd.read_csv(path, sep=None, engine="python")
        return df
    if ext in (".xlsx", ".xls"):
        return pd.read_excel(path)
    if ext == ".json":
        # Covers JSON array-of-records, JSON-lines, and nested-record JSON.
        try:
            return pd.read_json(path)
        except ValueError:
            return pd.read_json(path, lines=True)
    if ext in (".parquet", ".pq"):
        return pd.read_parquet(path)
    raise ValueError(f"Unsupported file extension: {ext}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file", help="Path to the dataset file")
    args = parser.parse_args()

    path = Path(args.file).expanduser().resolve()
    if not path.exists():
        sys.exit(f"File not found: {path}")

    print("=" * 78)
    print(f"FILE: {path}")
    print(f"SIZE: {os.path.getsize(path) / 1024:.1f} KB")
    print("=" * 78)

    df = load_any(path)

    # ---- 1. Shape -------------------------------------------------------------
    print(f"\n[1] SHAPE: {df.shape[0]} rows × {df.shape[1]} columns")

    # ---- 2. Column names ------------------------------------------------------
    print("\n[2] COLUMNS:")
    for i, c in enumerate(df.columns, 1):
        print(f"    {i:>2}. {c!r}")

    # ---- 3. dtypes ------------------------------------------------------------
    print("\n[3] DTYPES:")
    print(df.dtypes.to_string())

    # ---- 4. First / last rows -------------------------------------------------
    pd.set_option("display.max_columns", 50)
    pd.set_option("display.width", 200)
    print("\n[4] FIRST 5 ROWS:")
    print(df.head(5).to_string())
    print("\n[5] LAST 5 ROWS:")
    print(df.tail(5).to_string())

    # ---- 6. Missing values ----------------------------------------------------
    missing = df.isna().sum().sort_values(ascending=False)
    print("\n[6] MISSING VALUES (count, %):")
    for col, n in missing.items():
        print(f"    {col!r:<40} {n:>8}  ({n / max(len(df), 1) * 100:5.2f}%)")

    # ---- 7. Duplicates (full-row) --------------------------------------------
    n_dup = df.duplicated().sum()
    print(f"\n[7] FULL-ROW DUPLICATES: {n_dup}")

    # ---- 8. Descriptive statistics (numerical columns only) ------------------
    print("\n[8] DESCRIPTIVE STATS (numeric columns):")
    num_cols = df.select_dtypes(include=[np.number]).columns.tolist()
    if num_cols:
        print(df[num_cols].describe().T.to_string())
    else:
        print("    (No numeric columns detected.)")

    # ---- 9. Categorical / low-cardinality columns ----------------------------
    print("\n[9] LOW-CARDINALITY COLUMNS (<= 20 unique values) — possible labels/IDs:")
    for col in df.columns:
        nunq = df[col].nunique(dropna=True)
        if nunq <= 20:
            vals = df[col].dropna().unique()[:10]
            print(f"    {col!r:<40} n_unique={nunq:>4}  sample={list(vals)[:10]}")

    # ---- 10. Column with high uniqueness (candidate IDs/timestamps) ----------
    print("\n[10] HIGH-CARDINALITY COLUMNS (> 50% unique rows) — candidate IDs/timestamps:")
    n = len(df)
    for col in df.columns:
        nunq = df[col].nunique(dropna=True)
        if n > 0 and nunq / n > 0.5:
            print(f"    {col!r:<40} n_unique={nunq:>8}  ratio={nunq/n:.3f}  sample={df[col].dropna().head(3).tolist()}")

    # ---- 11. Sample of suspicious values (constant / sentinel) --------------
    print("\n[11] CONSTANT COLUMNS (single unique value):")
    for col in df.columns:
        if df[col].nunique(dropna=True) == 1:
            print(f"    {col!r} = {df[col].dropna().iloc[0]!r}")

    print("\n[12] INSPECTION COMPLETE.")
    print("=" * 78)
    print("NEXT: Paste the FULL output above back to me.")
    print("We will then run schema-aware checks (timestamp monotonicity,")
    print("per-sensor grouping, value ranges, correlation with any labels).")
    print("=" * 78)


if __name__ == "__main__":
    main()