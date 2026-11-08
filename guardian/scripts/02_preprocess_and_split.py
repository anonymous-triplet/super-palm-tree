import pandas as pd
from datetime import timedelta

print("Loading raw data...")
df = pd.read_csv("data/raw/2018_SCADA_Pressures.csv", sep=';', decimal=',')
df['Timestamp'] = pd.to_datetime(df['Timestamp'])
df = df.sort_values('Timestamp').reset_index(drop=True)

print("Extracting real leak labels...")
repair_times = pd.to_datetime([
    "2018-04-02 11:40", "2018-02-10 09:20", "2018-03-23 10:25",
    "2018-05-29 21:20", "2018-06-02 06:05", "2018-06-12 03:00",
    "2018-08-12 17:30", "2018-09-01 17:10", "2018-10-23 13:35",
    "2018-11-08 20:25"
])

df['label'] = 0
window = timedelta(hours=48)
for rt in repair_times:
    start_time = rt - window
    df.loc[(df['Timestamp'] >= start_time) & (df['Timestamp'] <= rt), 'label'] = 1

print("Splitting data chronologically (80% Train, 20% Test)...")
split_idx = int(len(df) * 0.8)
train_df = df.iloc[:split_idx].copy()
test_df = df.iloc[split_idx:].copy()

# Save to processed folder
train_df.to_csv("data/processed/train_data.csv", index=False)
test_df.to_csv("data/processed/test_data.csv", index=False)

print(f"Train set: {len(train_df)} rows ({train_df['label'].sum()} leak rows)")
print(f"Test set:  {len(test_df)} rows ({test_df['label'].sum()} leak rows)")
print("Saved to data/processed/")
