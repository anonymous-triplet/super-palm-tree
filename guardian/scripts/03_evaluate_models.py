import pandas as pd
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, confusion_matrix

print("Loading processed data...")
train_df = pd.read_csv("data/processed/train_data.csv")
test_df = pd.read_csv("data/processed/test_data.csv")

sensor_cols = [c for c in train_df.columns if c not in ['Timestamp', 'label']]
X_train = train_df[sensor_cols]
y_train = train_df['label']
X_test = test_df[sensor_cols]
y_test = test_df['label']

# Scale data
scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)
X_test_scaled = scaler.transform(X_test)

def print_results(model_name, y_true, y_pred):
    print("\n" + "="*60)
    print(f"MODEL: {model_name}")
    print("="*60)
    print("Confusion Matrix:")
    print(confusion_matrix(y_true, y_pred))
    print("\nClassification Report:")
    print(classification_report(y_true, y_pred, target_names=["Normal", "Leak"], zero_division=0))

# --- 1. Classical (Logistic Regression) ---
lr = LogisticRegression(max_iter=1000, class_weight='balanced')
lr.fit(X_train_scaled, y_train)
print_results("Classical (Logistic Regression)", y_test, lr.predict(X_test_scaled))

# --- 2. Supervised (Random Forest) ---
rf = RandomForestClassifier(n_estimators=100, class_weight='balanced', random_state=42, n_jobs=-1)
rf.fit(X_train, y_train)
print_results("Supervised (Random Forest)", y_test, rf.predict(X_test))

# --- 3. Unsupervised (Isolation Forest) ---
X_train_normal = X_train[y_train == 0]
iso = IsolationForest(contamination=0.05, random_state=42, n_jobs=-1)
iso.fit(X_train_normal)
iso_preds = np.where(iso.predict(X_test) == -1, 1, 0)
print_results("Unsupervised (Isolation Forest)", y_test, iso_preds)