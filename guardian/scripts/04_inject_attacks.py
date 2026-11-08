import pandas as pd
import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.metrics import classification_report, confusion_matrix

print("Loading processed data...")
train_df = pd.read_csv("data/processed/train_data.csv")
test_df = pd.read_csv("data/processed/test_data.csv")

# Convert Timestamp back to datetime for easy filtering
test_df['Timestamp'] = pd.to_datetime(test_df['Timestamp'])

# ==========================================
# 1. ATTACK INJECTION
# ==========================================
# We copy the test data so we don't destroy the original file
attack_df = test_df.copy()
attack_df['is_attack'] = 0  # 0 = Normal/Leak, 1 = Cyberattack

# --- ATTACK A: SENSOR SPOOFING (n215) ---
# Let's hack sensor n215 and force it to read 90.0 for 2 hours.
# (Normally, n215 is around 39.09)
spoof_start = "2018-11-20 10:00:00"
spoof_end = "2018-11-20 12:00:00"
spoof_mask = (attack_df['Timestamp'] >= spoof_start) & (attack_df['Timestamp'] <= spoof_end)

attack_df.loc[spoof_mask, 'n215'] = 90.0
attack_df.loc[spoof_mask, 'is_attack'] = 1
print(f"Injected {spoof_mask.sum()} rows of Spoofing Attack on sensor n215.")

# --- ATTACK B: REPLAY ATTACK (n1) ---
# Let's take 2 hours of normal data from January 1st (in the train set)
# and replay it on November 21st (in the test set).
replay_source_mask = (pd.to_datetime(train_df['Timestamp']) >= "2018-01-01 00:00:00") & \
                     (pd.to_datetime(train_df['Timestamp']) <= "2018-01-01 02:00:00")
replay_source_data = train_df.loc[replay_source_mask, 'n1'].values

replay_target_start = "2018-11-21 00:00:00"
replay_target_end = "2018-11-21 02:00:00"
replay_target_mask = (attack_df['Timestamp'] >= replay_target_start) & \
                     (attack_df['Timestamp'] <= replay_target_end)

# Apply the replay
if replay_target_mask.sum() == len(replay_source_data):
    attack_df.loc[replay_target_mask, 'n1'] = replay_source_data
    attack_df.loc[replay_target_mask, 'is_attack'] = 1
    print(f"Injected {replay_target_mask.sum()} rows of Replay Attack on sensor n1.")
else:
    print("Error: Replay data lengths do not match.")

# ==========================================
# 2. MODEL TRAINING & PREDICTION
# ==========================================
sensor_cols = [c for c in train_df.columns if c not in ['Timestamp', 'label']]

# Train ONLY on the clean, normal data from the training set (label == 0)
print("\nTraining Isolation Forest on normal behavior...")
X_train_normal = train_df[train_df['label'] == 0][sensor_cols]
iso = IsolationForest(contamination=0.05, random_state=42, n_jobs=-1)
iso.fit(X_train_normal)

# Predict on the attacked test data
print("Scanning the attacked data...")
X_attack = attack_df[sensor_cols]
# Predict returns 1 for normal, -1 for anomaly. We convert to 0 and 1.
preds_binary = np.where(iso.predict(X_attack) == -1, 1, 0)

# ==========================================
# 3. EVALUATION
# ==========================================
# Note: We are evaluating against 'is_attack' (the cyberattacks we just added)
y_true = attack_df['is_attack']

print("\n" + "="*60)
print("PHASE 2: CYBERATTACK DETECTION RESULTS")
print("="*60)
print("Confusion Matrix:")
print(confusion_matrix(y_true, preds_binary))

print("\nClassification Report:")
print(classification_report(y_true, preds_binary, target_names=["Normal", "Cyberattack"], zero_division=0))

# Breakdown of which attacks were caught
attack_df['predicted_attack'] = preds_binary
caught = attack_df[(attack_df['is_attack'] == 1) & (attack_df['predicted_attack'] == 1)]
missed = attack_df[(attack_df['is_attack'] == 1) & (attack_df['predicted_attack'] == 0)]

print(f"\nTotal Attack Rows: {y_true.sum()}")
print(f"Attacks Caught by Model: {len(caught)}")
print(f"Attacks Missed by Model: {len(missed)}")
print("="*60)