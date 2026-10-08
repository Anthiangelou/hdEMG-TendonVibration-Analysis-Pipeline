# hdEMG-TendonVibration-Analysis-Pipeline


A MATLAB data analysis pipeline designed for processing High-Density Electromyography (hdEMG) and individual Motor Unit (MU) discharge characteristics during Tendon Vibration (TV) protocols.

## Overview
This pipeline automatically extracts, analyzes, and quantifies single motor unit firing patterns and biomechanical parameters from MUedit-decomposed files. It evaluates the impact of reflex stimulation (tendon vibration) across defined steady-state contraction epochs.

## Key Features & Neuromechanistic Metrics
- **Epoch Extraction:** Standardized analysis across *BeforeTV*, *immTV* (immediate response), and *endTV* (plateau/fatigue).
- **Motor Unit Firing Statistics:** Calculates Mean Discharge Rate (MDR), Median DR, Mean ISI, SD ISI, and Coefficient of Variation of ISI (CoV-ISI).
- **Cumulative Spike Train (CST) & Neural Drive:** Computes filtered CST (fCST), high-pass filtered fCST, and time-varying SD of fCST.
- **Force Variability & Cross-Correlation:** Evaluates linear Pearson correlations and time-lagged cross-correlations ($r$, lag) between neural drive variability (SD-fCST) and force steadiness (Force CoV).
- **Automated Quality Control (QC):** Detects TV onset, plateau regions, signal polarity, and exports dynamic QC raster plots and summary Excel/MAT structures.

## Usage
1. Place decomposed `.mat` files (from MUedit) in your working directory.
2. Run `TV_MU_Timepoint_Analysis_SIGNALDATA_V4.m` in MATLAB.
3. Select the data files via the user interface.
4. Exported results will be saved automatically as an Excel workbook (`.xlsx`) and a compiled dataset (`.mat`).

##  Author
**Anthi Angelou**  
MSc in Kinesiology | Neuromechanics & Electrophysiology  
[GitHub Profile](https://github.com/Anthiangelou)
