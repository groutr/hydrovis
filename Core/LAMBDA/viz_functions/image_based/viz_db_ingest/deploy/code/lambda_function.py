################################################################################
################################ Viz DB Ingest ################################# 
################################################################################
"""
This function downloads a file from S3 and ingets it into the vizprocessing RDS
database.

Args:
    event (dictionary): The event passed from the state machine.
    context (object): Automatic metadata regarding the invocation.
    
Returns:
    dictionary: The details of the file that was ingested, to be returned to the state machine.
"""
################################################################################
import fsspec
import json
import re
from datetime import datetime
import numpy as np
import pandas as pd
import xarray as xr
from io import StringIO
from psycopg2.errors import UndefinedTable, BadCopyFileFormat, InvalidTextRepresentation

from viz_s3 import check_file_source
from viz_database import VizDatabase


class MissingS3FileException(Exception):
    """ my custom exception class """

class UnrecognizedInput(Exception):
    pass

def lambda_handler(event, context):

    target_table = event['target_table']
    target_cols = event['target_cols']
    file = event['file']
    bucket = event['bucket']
    reference_time = event['reference_time']
    keep_flows_at_or_above = event['keep_flows_at_or_above']
    reference_time_dt = datetime.strptime(reference_time, '%Y-%m-%d %H:%M:%S')
    create_table = event.get('iteration_index') == 0
    
    print(f"Checking existance of {file} on S3/Google Cloud/Para Nomads.")
    download_path = check_file_source(bucket, file)
    
    if not target_table:
        dump_dict = {
            "file": file,
            "target_table": target_table,
            "reference_time": reference_time,
            "rows_imported": 0
        }
        return json.dumps(dump_dict)
    
    viz_db = VizDatabase(db_type="viz")
    nwm_version = 0

    if file.endswith('.nc'):
        ds = xr.open_dataset(download_path, engine="h5netcdf", chunks={})
        ds_vars = list(ds.variables.keys())

        if not target_cols:
            target_cols = ds_vars

        forecast_hour = re.search(r"\d{8}/[a-z0-9_]*/.*t\d{2}z.*[ftm](\d*)\.", file)
        if forecast_hour:
            forecast_hour = int(forecast_hour.group(1))
            if "hawaii" in file:
                forecast_hour = forecast_hour // 100

            if 'forecast_hour' not in target_cols:
                target_cols.append('forecast_hour')
        else:
            raise ValueError("Regex pattern for the forecast hour didn't match the netcdf file")

        if "NWM_version_number" in ds.attrs:
            nwm_vers = ds.attrs["NWM_version_number"]
        elif "model_version" in ds.attrs:
            nwm_vers = ds.attrs['model_version']
        else:
            raise ValueError("NWM version not found in netcdf file")
        
        if isinstance(nwm_vers, str):
            nwm_vers = nwm_vers.replace("v", "")
        else:
            nwm_vers = nwm_vers.values[0].replace("v", "")
        if "nwm_vers" not in target_cols:
            target_cols.append('nwm_vers')
            
        #drop_vars = [var for var in ds_vars if var not in target_cols]
        sel_vars = ds.variables.keys() & target_cols
        df = ds[list(sel_vars)].to_dataframe().reset_index()
        #df = df.drop(columns=drop_vars)
        ds.close()
        if 'streamflow' in target_cols:
            df = df.loc[df['streamflow'] >= keep_flows_at_or_above].round({'streamflow': 2})  # noqa
        df['nwm_vers'] = nwm_vers
        df['forecast_hour'] = forecast_hour
    elif file.endswith('.csv'):
        df = pd.read_csv(download_path)
    else:
        raise UnrecognizedInput(f"File format not supported. {file}")

    print(f"--> Preparing and Importing {file}")
    f = StringIO()  # Use StringIO to store the temporary text file in memory (faster than on disk)
    df.to_csv(f, sep='\t', index=False, header=False)
    try:
        with viz_db.connection.cursor() as cur:
            f.seek(0)
            cur.copy_from(f, target_table, sep='\t', null='')
    except (UndefinedTable, BadCopyFileFormat, InvalidTextRepresentation):
        if not create_table:
            raise

        print("Error encountered. Recreating table now and retrying import...")
        create_table_df = df.head(0)
        schema, table = target_table.split('.')
        create_table_df.to_sql(con=viz_db.engine, schema=schema, name=table, index=False, if_exists='replace')
        with viz_db.connection.cursor() as cur:
            f.seek(0)
            cur.copy_from(f, target_table, sep='\t', null='')

    print(f"--> Import of {len(df)} rows Complete. Removing {download_path} and closing db connection.")
    os.remove(download_path)

    dump_dict = {
                        "file": file,
                        "target_table": target_table,
                        "reference_time": reference_time,
                        "rows_imported": len(df),
                        "nwm_version": nwm_version
                    }
    return json.dumps(dump_dict)    # Return some info on the import
