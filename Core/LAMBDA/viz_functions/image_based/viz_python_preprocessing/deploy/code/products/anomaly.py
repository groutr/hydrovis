import numpy as np
import pandas as pd
import xarray as xr
import fsspec
import os
from viz_lambda_shared_funcs import check_if_file_exists

INSUFFICIENT_DATA_ERROR_CODE = -9998
PERCENTILE_TABLE_5TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_5th_perc.nc"
PERCENTILE_TABLE_10TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_10th_perc.nc"
PERCENTILE_TABLE_25TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_25th_perc.nc"
PERCENTILE_TABLE_75TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_75th_perc.nc"
PERCENTILE_TABLE_90TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_90th_perc.nc"
PERCENTILE_TABLE_95TH = "viz_authoritative_data/derived_data/nwm_v21_7_day_average_percentiles/final_7day_all_95th_perc.nc"
PERCENTILE_14_TABLE_5TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_5th_perc.nc"
PERCENTILE_14_TABLE_10TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_10th_perc.nc"
PERCENTILE_14_TABLE_25TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_25th_perc.nc"
PERCENTILE_14_TABLE_75TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_75th_perc.nc"
PERCENTILE_14_TABLE_90TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_90th_perc.nc"
PERCENTILE_14_TABLE_95TH = "viz_authoritative_data/derived_data/nwm_v21_14_day_average_percentiles/final_14day_all_95th_perc.nc"

PVALS = (5, 10, 25, 75, 90, 95)
SEVEN_DAY_P = (PERCENTILE_TABLE_5TH,
               PERCENTILE_TABLE_10TH,
               PERCENTILE_TABLE_25TH,
               PERCENTILE_TABLE_75TH,
               PERCENTILE_TABLE_90TH,
               PERCENTILE_TABLE_95TH)

FOURTEEN_DAY_P = (PERCENTILE_14_TABLE_5TH,
               PERCENTILE_14_TABLE_10TH,
               PERCENTILE_14_TABLE_25TH,
               PERCENTILE_14_TABLE_75TH,
               PERCENTILE_14_TABLE_90TH,
               PERCENTILE_14_TABLE_95TH)

def s3ify(uri, bucket=None):
    if uri.startswith('http'):
        return uri
    if bucket is None:
        raise ValueError("Bucket required for non http")
    return f"s3://{bucket}/{uri}"

def run_anomaly(reference_time, fileset_bucket, fileset, output_file_bucket, output_file, auth_data_bucket, anomaly_config=7):
    average_flow_col = f'average_flow_{anomaly_config}day'
    anom_col = f'anom_cat_{anomaly_config}day'
    date = int(reference_time.strftime("%j")) - 1  # retrieves the date in integer form from reference_time

    s3 = fsspec.filesystem('s3')
    ##### Data Prep ####
    if anomaly_config == 7:
        percentile_files = SEVEN_DAY_P
    elif anomaly_config == 14:
        percentile_files = FOURTEEN_DAY_P
    else:
        raise Exception("Anomaly config must be 7 or 14 for the appropriate percentile files")
    
    percentiles = {}
    for v, p in zip(PVALS, percentile_files):
        path = f"s3://{auth_data_bucket}/{p}"
        with xr.open_dataset(s3.open(path), engine='h5netcdf', chunks={}) as ds:
            p_col = ds.streamflow.sel(time=date)
            p_col = (p_col* 35.3147).round(2)  # convert streamflow from cms to cfs
            percentiles[f"prcntle_{v}"] = p_col.to_pandas()

    #Get NWM version from first file
    first_file_path = check_if_file_exists(fileset_bucket, fileset[0], download=True, download_subfolder=reference_time.strftime('%Y%m%d'))
    with xr.open_dataset(first_file_path) as first_file:
        nwm_vers = first_file.NWM_version_number.replace("v","")
    os.remove(first_file_path)
    
    # Loop through filepaths, download file, and import data into pandas - we have to delete files as we go on anomaly, or else the lambda storage will fill up.
    print("-->Looping through files to get streamflow sum")
    df = pd.DataFrame()
    for file in fileset:
        download_path = check_if_file_exists(fileset_bucket, file, download=True, download_subfolder=reference_time.strftime('%Y%m%d'))
        
        with xr.open_dataset(download_path) as ds_file:
            df_file = ds_file['streamflow'].to_dataframe()
            df_file['streamflow']  = df_file['streamflow'] * 35.3147  # convert streamflow from cms to cfs
    
            if df.empty:
                df = df_file
                df = df.rename(columns={"streamflow": "streamflow_sum"})
            else:
                df['streamflow_sum'] += df_file['streamflow']
        os.remove(download_path)

    df[average_flow_col] = df['streamflow_sum'] / len(fileset)
    df = df.drop(columns=['streamflow_sum'])
    df[average_flow_col] = df[average_flow_col].round(2)

    # Import Percentile Data
    print("-->Importing percentile data:")

    date = int(reference_time.strftime("%j")) - 1  # retrieves the date in integer form from reference_time

    print(f"---->Retrieving {anomaly_config} day 5th percentiles...")
    ds_perc = xr.open_dataset(percentile_5)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_5"})
    df_perc['prcntle_5'] = (df_perc['prcntle_5'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print(f"---->Retrieving {anomaly_config} day 10th percentiles...")
    ds_perc = xr.open_dataset(percentile_10)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_10"})
    df_perc['prcntle_10'] = (df_perc['prcntle_10'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print(f"---->Retrieving {anomaly_config} day 25th percentiles...")
    ds_perc = xr.open_dataset(percentile_25)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_25"})
    df_perc['prcntle_25'] = (df_perc['prcntle_25'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print(f"---->Retrieving {anomaly_config} day 75th percentiles...")
    ds_perc = xr.open_dataset(percentile_75)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_75"})
    df_perc['prcntle_75'] = (df_perc['prcntle_75'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print(f"---->Retrieving {anomaly_config} day 90th percentiles...")
    ds_perc = xr.open_dataset(percentile_90)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_90"})
    df_perc['prcntle_90'] = (df_perc['prcntle_90'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print(f"---->Retrieving {anomaly_config} day 95th percentiles...")
    ds_perc = xr.open_dataset(percentile_95)
    df_perc = ds_perc.sel(time=date)['streamflow'].to_dataframe()
    df_perc = df_perc.rename(columns={"streamflow": "prcntle_95"})
    df_perc['prcntle_95'] = (df_perc['prcntle_95'] * 35.3147).round(2)  # convert streamflow from cms to cfs
    df = df.join(df_perc)

    print("---->Creating percentile dictionary...")
    labels = {
        0: "Low (<= 5th)",
        1: "Much Below Normal (6th - 10th)",
        2: "Below Normal (11th - 25th))",
        3: "Normal (26th - 75th)",
        4: "Above Normal (76th - 90th)",
        5: "Much Above Normal (91st - 95th)",
        6: "High (> 95th)"
    }
    df[anom_col] = np.nan
    df.loc[(df[average_flow_col] >= df['prcntle_95']) & df[anom_col].isna(), anom_col] = 6
    df.loc[(df[average_flow_col] >= df['prcntle_90']) & df[anom_col].isna(), anom_col] = 5 # noqa: E501
    df.loc[(df[average_flow_col] >= df['prcntle_75']) & df[anom_col].isna(), anom_col] = 4
    df.loc[(df[average_flow_col] >= df['prcntle_25']) & df[anom_col].isna(), anom_col] = 3
    df.loc[(df[average_flow_col] >= df['prcntle_10']) & df[anom_col].isna(), anom_col] = 2
    df.loc[(df[average_flow_col] >= df['prcntle_5']) & df[anom_col].isna(), anom_col] = 1
    df.loc[(df[average_flow_col] < df['prcntle_5']) & df[anom_col].isna(), anom_col] = 0
    df[anom_col] = df[anom_col].map(labels)
    df = df.replace(round(INSUFFICIENT_DATA_ERROR_CODE * 35.3147, 2), None)
    df['nwm_vers'] = nwm_vers

    print("Uploading output CSV file to S3")
    s3_file = f"s3://{output_file_bucket}/{output_file}"
    df = df.reset_index()
    df.to_csv(s3_file, index=False)
    print("--- Uploaded to", s3_file)
