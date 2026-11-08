import pandas as pd
import numpy as np
from sklearn.metrics import classification_report, confusion_matrix

print("Loading data...")
train_df = pd.read_csv("data/processed/train_data.csv")
test_df = pd.read_csv("data/processed/test_data.csv")
test_df['Timestamp'] = pd.to_datetime(test_df['Timestamp'])

attack_df = test_df.copy()
attack_df['is_attack'] = 0

# --- INJECT ATTACKS ---
# Spoofing n215 to 90.0 for 24 hours
spoof_mask = (attack_df['Timestamp'] >= "2018-11-20 00:00:00") & (attack_df['Timestamp'] <= "2018-11-21 00:00:00")
attack_df.loc[spoof_mask, 'n215'] = 90.0
attack_df.loc[spoof_mask, 'is_attack'] = 1

# Replay n1 for 24 hours
replay_source = train_df[(pd.to_datetime(train_df['Timestamp']) >= "2018-01-01 00:00:00") & 
                         (pd.to_datetime(train_df['Timestamp']) < "2018-01-02 00:00:00")]['n1'].values
replay_mask = (attack_df['Timestamp'] >= "2018-11-22 00:00:00") & (attack_df['Timestamp'] < "2018-11-23 00:00:00")
attack_df.loc[replay_mask, 'n1'] = replay_source
attack_df.loc[replay_mask, 'is_attack'] = 1

# ==========================================
# GUARDIAN DETECTOR
# ==========================================
sensor_cols = [c for c in train_df.columns if c not in ['Timestamp', 'label']]
final_predictions = np.zeros(len(attack_df))

print("Calculating thresholds from normal training data...")
# Rule 1 & 3: Statistical Z-Score Limits (Mean and Std Dev)
means = train_df[train_df['label'] == 0][sensor_cols].mean()
stds = train_df[train_df['label'] == 0][sensor_cols].std()

# Rule 2: Max Rate of Change
max_changes = train_df[train_df['label'] == 0][sensor_cols].diff().abs().max()

# --- DETECT SPOOFING (Statistical + Rate of Change) ---
print("Detecting Spoofing...")
for i in range(len(attack_df)):
    for sensor in sensor_cols:
        val = attack_df.iloc[i][sensor]
        mean = means[sensor]
        std = stds[sensor]
        
        # Z-score check: If value is more than 5 std devs away from normal
        if std > 0 and abs(val - mean) > (5 * std):
            final_predictions[i] = 1
            break # Break inner loop if anomaly found
            
        # Rate of change check (if this isn't the first row)
        if i > 0:
            change = abs(val - attack_df.iloc[i-1][sensor])
            if change > max_changes[sensor]:
                final_predictions[i] = 1
                break

# --- DETECT REPLAY (Exact Sequence Match) ---
print("Detecting Replay...")
# We look at the sequence of values for each sensor. 
# If a 24-hour block is identical to the past, it's a replay.
for sensor in sensor_cols:
    # Get training values as a continuous string
    train_str = ",".join(train_df[sensor].astype(str).values)
    # Check 2-hour blocks in the attack data
    for i in range(0, len(attack_df) - 24, 24): # Check in 2-hour increments
        block = ",".join(attack_df[sensor].iloc[i:i+24].astype(str).values)
        if block in train_str:
            final_predictions[i:i+24] = 1 # Flag the whole block

# ==========================================
# EVALUATION
# ==========================================
y_true = attack_df['is_attack']

print("\n" + "="*60)
print("FINAL GUARDIAN DETECTOR RESULTS")
print("="*60)
print("Confusion Matrix:")
print(confusion_matrix(y_true, final_predictions))

print("\nClassification Report:")
print(classification_report(y_true, final_predictions, target_names=["Normal", "Cyberattack"], zero_division=0))

caught = attack_df[(attack_df['is_attack'] == 1) & (final_predictions == 1)]
missed = attack_df[(attack_df['is_attack'] == 1) & (final_predictions == 0)]

print(f"\nTotal Attack Rows: {y_true.sum()}")
print(f"Attacks Caught: {len(caught)}")
print(f"Attacks Missed: {len(missed)}")