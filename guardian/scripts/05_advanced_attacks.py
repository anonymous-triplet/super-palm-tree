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

# ==========================================
# 1. INJECT LARGER ATTACKS (24 hours)
# ==========================================
# Spoof n215 to 90.0 for a full 24 hours
spoof_mask = (attack_df['Timestamp'] >= "2018-11-20 00:00:00") & \
             (attack_df['Timestamp'] <= "2018-11-21 00:00:00")
attack_df.loc[spoof_mask, 'n215'] = 90.0
attack_df.loc[spoof_mask, 'is_attack'] = 1

# Replay n1 for a full 24 hours
replay_source = train_df[(pd.to_datetime(train_df['Timestamp']) >= "2018-01-01 00:00:00") & 
                         (pd.to_datetime(train_df['Timestamp']) < "2018-01-02 00:00:00")]['n1'].values

replay_mask = (attack_df['Timestamp'] >= "2018-11-22 00:00:00") & \
              (attack_df['Timestamp'] < "2018-11-23 00:00:00")

if replay_mask.sum() == len(replay_source):
    attack_df.loc[replay_mask, 'n1'] = replay_source
    attack_df.loc[replay_mask, 'is_attack'] = 1

print(f"Total attack rows injected: {attack_df['is_attack'].sum()}")

# ==========================================
# 2. FEATURE ENGINEERING (Crucial step!)
# ==========================================
# We will add a "Rate of Change" feature. 
# This calculates the difference between the current row and the previous row.
# A hacker spoofing the sensor will cause a massive spike in Rate of Change.
sensor_cols = [c for c in train_df.columns if c not in ['Timestamp', 'label']]

def add_features(df):
    df_feat = df[sensor_cols].copy()
    # Calculate the difference from the previous reading
    df_diff = df[sensor_cols].diff().fillna(0)
    df_diff.columns = [f"{c}_diff" for c in sensor_cols]
    return pd.concat([df_feat, df_diff], axis=1)

X_train_feat = add_features(train_df)
X_attack_feat = add_features(attack_df)

# ==========================================
# 3. TRAIN & PREDICT
# ==========================================
# Train ONLY on normal data from the training set
X_train_normal = X_train_feat[train_df['label'] == 0]

print("Training Isolation Forest with Rate-of-Change features...")
# We lower contamination to 0.01 because our attacks are very targeted now
iso = IsolationForest(contamination=0.01, random_state=42, n_jobs=-1)
iso.fit(X_train_normal)

print("Scanning for anomalies...")
preds_binary = np.where(iso.predict(X_attack_feat) == -1, 1, 0)
y_true = attack_df['is_attack']

# ==========================================
# 4. EVALUATION
# ==========================================
print("\n" + "="*60)
print("PHASE 2: ADVANCED ATTACK DETECTION RESULTS")
print("="*60)
print("Confusion Matrix:")
print(confusion_matrix(y_true, preds_binary))

print("\nClassification Report:")
print(classification_report(y_true, preds_binary, target_names=["Normal", "Cyberattack"], zero_division=0))

caught = attack_df[(attack_df['is_attack'] == 1) & (preds_binary == 1)]
missed = attack_df[(attack_df['is_attack'] == 1) & (preds_binary == 0)]

print(f"\nTotal Attack Rows: {y_true.sum()}")
print(f"Attacks Caught by Model: {len(caught)}")
print(f"Attacks Missed by Model: {len(missed)}")