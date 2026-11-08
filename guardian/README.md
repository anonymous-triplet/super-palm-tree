# Guardian Layer — Smart City Self-Healing

**Project:** IEEE TSYP14 — City Brain Convergence — Phase 1  
**Goal:** Detect anomalies and cyberattacks in critical infrastructure sensor data.

## What This Project Does

The Guardian Layer sits between the sensor network and the City Brain. Its job is to answer:

> *"Can we trust this sensor reading, or is it suspicious?"*

This repository contains the complete experimental pipeline:

1. **Phase 1 — Model Comparison:** Trains and compares three learning paradigms (Classical, Supervised, Unsupervised) on real leak detection.
2. **Phase 2 — Cyberattack Injection:** Simulates Spoofing and Replay attacks against the sensor stream.
3. **Phase 3 — Hybrid Guardian:** Implements a rule-based + statistical detector that catches **100% of injected attacks**.

## Dataset

We use the **BattLeDIM 2020 L-Town** benchmark (Vrachimis et al., 2022). The SCADA data is NOT included in this repository (too large + licensing). Download it manually:

1. Go to `https://zenodo.org/records/4017659`
2. Download `2018_SCADA_Pressures.csv` and `2018_Fixed_Leakages_Report.txt`
3. Place them in `data/raw/`

## Installation

```bash
python -m venv .venv
# Windows:
.venv\Scripts\activate
# macOS/Linux:
source .venv/bin/activate

pip install -r requirements.txt