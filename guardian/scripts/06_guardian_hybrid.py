import pandas as pd
import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.metrics import classification_report, confusion_matrix

print("Loading data...")
train_df = pd.read_csv("data/processed/train_data.csv")
test_df = pd.read_csv("data/processed/test_data.csv")
test_df['Timestamp'] = pd.to_datetime(test_df['Timestamp'])

attack_df = test_df.copy()
attack_df['is_attack'] = 0

# --- INJECT ATTACKS ---
# 1. Spoofing n215 to 90.0 for 24 hours
spoof_mask = (attack_df['Timestamp'] >= "2018-11-20 00:00:00") & \
             (attack_df['Timestamp'] <= "2018-11-21 00:00:00")
attack_df.loc[spoof_mask, 'n215'] = 90.0
attack_df.loc[spoof_mask, 'is_attack'] = 1

# 2. Replay n1 for 24 hours
replay_source = train_df[(pd.to_datetime(train_df['Timestamp']) >= "2018-01-01 00:00:00") & 
                         (pd.to_datetime(train_df['Timestamp']) < "2018-01-02 00:00:00")]['n1'].values
replay_mask = (attack_df['Timestamp'] >= "2018-11-22 00:00:00") & \
              (attack_df['Timestamp'] < "2018-11-23 00:00:00")
attack_df.loc[replay_mask, 'n1'] = replay_source
attack_df.loc[replay_mask, 'is_attack'] = 1

# ==========================================
# HYBRID ARCHITECTURE
# ==========================================
sensor_cols = [c for c in train_df.columns if c not in ['Timestamp', 'label']]
final_predictions = np.zeros(len(attack_df))

# --- PART 1: UNSUPERVISED PER-SENSOR ML ---
print("Training 33 Isolation Forests (one for each sensor)...")
for sensor in sensor_cols:
    # Train on normal data for this specific sensor
    X_train_single = train_df[train_df['label'] == 0][[sensor]]
    iso = IsolationForest(contamination=0.01, random_state=42)
    iso.fit(X_train_single)
    
    # Predict on the attacked data for this specific sensor
    X_attack_single = attack_df[[sensor]]
    preds = iso.predict(X_attack_single)
    
    # If the sensor is an anomaly (-1), we flag it
    anomaly_indices = np.where(preds == -1)[0]
    final_predictions[anomaly_indices] = 1

# --- PART 2: RULE-BASED REPLAY DETECTION ---
print("Applying Rule-Based Replay Detection...")
# We check if any row in the attack data exactly matches a row in the training data.
# (In a real system, you would check timestamps and message IDs, but this simulates it).
# We will use a hash of the sensor values to find exact duplicates.
train_hashes = set(pd.util.hash_pandas_object(train_df[sensor_cols], index=False))
attack_hashes = pd.util.hash_pandas_object(attack_df[sensor_cols], index=False)

for i, h in enumerate(attack_hashes):
    if h in train_hashes:
        final_predictions[i] = 1  # Rule: Flag as Replay Attack

# ==========================================
# EVALUATION
# ==========================================
y_true = attack_df['is_attack']

print("\n" + "="*60)
print("FINAL GUARDIAN HYBRID ARCHITECTURE RESULTS")
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