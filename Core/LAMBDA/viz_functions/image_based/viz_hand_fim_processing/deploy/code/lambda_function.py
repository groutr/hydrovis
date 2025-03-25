import rasterio
from rasterio import windows as riowindows
from rasterio.features import shapes
import numpy as np
import pandas as pd
import geopandas as gpd
import os
import time
import datetime
from math import floor, ceil
from shapely.geometry import shape
import fsspec

from viz_classes import database

FIM_VERSION = os.environ['FIM_VERSION']
HAND_BUCKET = os.environ['HAND_BUCKET']
HAND_VERSION = os.environ['HAND_VERSION']
HAND_PREFIX = f"fim/hand_{HAND_VERSION.replace('.', '_')}/hand_datasets"

CACHE_FIM_RESOLUTION_FT = 0.25
CACHE_FIM_RESOLUTION_ROUNDING = 'up'

CACHED_S3 = fsspec.filesystem('blockcache', target_protocol='s3')


def lambda_handler(event, context):
    """
        The lambda handler is the function that is kicked off with the lambda. This function will coordinate
        the overall workflow from retrieving data, parsing it, kicking off the inundation workflow, saving the outputs,
        and then kicking off the next lambda which optimizes the raster for the cloud

        Args:
            event(event object): An event is a JSON-formatted document that contains data for a Lambda function to
                                 process
            context(object): Provides methods and properties that provide information about the invocation, function,
                             and runtime environment
    """
    # Parse the event argument to get the necessary arguments for the function
    run_values = event['run_values']
    reference_time = event['reference_time']
    product = event['product']
    fim_config = event['fim_config']
    data_bucket = event['data_bucket']
    data_prefix = event['data_prefix']
    fim_config_name = fim_config['name']
    db_fim_table = fim_config['target_table']
    process_by = fim_config.get('process_by', ['huc'])
    input_variable = fim_config.get('input_variable', 'flow')
    fim_run_type = 'normal'
    
    reference_date = datetime.datetime.strptime(reference_time, "%Y-%m-%d %H:%M:%S")
    date = reference_date.strftime("%Y%m%d")
    hour = reference_date.strftime("%H")
    huc8_branch = run_values['huc8_branch']
    huc8 = huc8_branch.split("-")[0]
    branch = huc8_branch.split("-")[1]
    s3_path_piece = ''
    
    # Get db table names and setup db connection
    db_schema = db_fim_table.split(".")[0]
    db_table = db_fim_table.split(".")[-1]
    if any(x in db_schema for x in ["aep", "fim_catchments", "catfim"]):
        fim_run_type = 'reference'
        process_db = database(db_type="egis")
        stage_ft_round_up = False # Don't round up to the nearest stage ft for reference services
    else:
        process_db = database(db_type="viz")
        stage_ft_round_up = True # Round up to the nearest stage ft for reference services
    
    if "catchments" in db_fim_table:
        df_inundation = create_inundation_catchment_boundary(huc8, branch)

        # print(f"Adding data to {db_fim_table}")# Only process inundation configuration if available data
        try:
            df_inundation.to_postgis(f"{db_table}", con=process_db.engine, schema=db_schema, if_exists='append')
        except Exception as e:
            raise Exception(f"Failed to add inundation data to DB for {huc8}-{branch} - ({e})") from e

    else:
        print(f"Processing HUC-branch {huc8_branch} for {fim_config_name} for {date}T{hour}:00:00Z")

        s3_path_piece = '/'.join([run_values[by] for by in process_by])
        subsetted_data = f"{data_prefix}/{product}/{fim_config_name}/workspace/{date}/{hour}/data/{s3_path_piece}_data.csv"

        if input_variable == 'stage':
            stage_lookup = s3_csv_to_df(data_bucket, subsetted_data)
            stage_lookup = stage_lookup.set_index('hydro_id')
        else:
            s3 = fsspec.filesystem('s3')
            # Validate main stem datasets by checking cathment, hand, and rating curves existence for the HUC
            catchment_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/gw_catchments_reaches_filtered_addedAttributes_{branch}.tif'
            catch_exists = s3.exists(f"s3://{HAND_BUCKET}/{catchment_key}")

            hand_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/rem_zeroed_masked_{branch}.tif'
            hand_exists = s3.exists(f"s3://{HAND_BUCKET}/{hand_key}")

            rating_curve_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/hydroTable_{branch}.csv'
            rating_curve_exists = s3.exists(f"s3://{HAND_BUCKET}/{rating_curve_key}")

            stage_lookup = pd.DataFrame()
            df_zero_stage_records = pd.DataFrame()
            if catch_exists and hand_exists and rating_curve_exists:
                # print("->Calculating flood depth")
                stage_lookup, df_zero_stage_records = calculate_stage_values(rating_curve_key, data_bucket, subsetted_data, huc8_branch)  # get stages
            else:
                print(f"catchment, hand, or rating curve are missing for huc {huc8} and branch {branch}:\nCatchment exists: {catch_exists} ({catchment_key})\nHand exists: {hand_exists} ({hand_key})\nRating curve exists: {rating_curve_exists} ({rating_curve_key})")
 
        # If not a reference/egis fim run, Upload zero_stage reaches for tracking / FIM cache
        if fim_run_type != 'reference' and not df_zero_stage_records.empty:
            # print(f"Adding zero stage data to {db_table}_zero_stage")# Only process inundation configuration if available data
            df_zero_stage_records.to_sql(f"{db_table}_zero_stage", con=process_db.engine, schema=db_schema, if_exists='append', index=False)
        
        # If no features with above zero stages are present, then just copy an unflood raster instead of processing nothing
        if stage_lookup.empty:
            print("No reaches with valid stages")
            return

        # Run the desired configuration
        df_inundation = create_inundation_output(huc8, branch, stage_lookup, reference_time, input_variable, stage_ft_round_up=stage_ft_round_up)

        # If not a reference run, split up the geometry into a seperate table for caching, upload no-stage data, and format dataframe accordingly
        if fim_run_type == 'normal':
            # Split geometry into seperate table per new schema
            df_inundation_geo = df_inundation[['hand_id', 'rc_stage_ft', 'geom']]
            df_inundation = df_inundation.drop(columns=['geom'])
            
            # If records exist in stage_lookup that don't exist in df_inundation, add those to the zero_stage table.
            df_no_inundation = stage_lookup.merge(df_inundation.drop_duplicates(), on=['hand_id'],how='left',indicator=True)
            df_no_inundation = df_no_inundation.loc[df_no_inundation['_merge'] == 'left_only']
            if df_no_inundation.empty == False:
                # print(f"Adding {len(df_no_inundation)} reaches with NaN inundation to zero_stage table")
                df_no_inundation = df_no_inundation.drop(df_no_inundation.columns.difference(['hand_id','rc_discharge_cms','note']), axis=1)
                df_no_inundation['note'] = "Error - No inundation returned from hand processing."
                df_no_inundation.to_sql(f"{db_table}_zero_stage", con=process_db.engine, schema=db_schema, if_exists='append', index=False)
            
            # If no records exist for valid inundation, stop.
            if df_inundation.empty:
                return
        
            # print(f"Adding data to {db_fim_table}")# Only process inundation configuration if available data
            try:
                df_inundation = df_inundation.drop(columns=['hydro_id', 'feature_id'])
                df_inundation.to_sql(db_table, con=process_db.engine, schema=db_schema, if_exists='append', index=False)
                df_inundation_geo.to_postgis(f"{db_table}_geo", con=process_db.engine, schema=db_schema, if_exists='append')
            except Exception as e:
                raise Exception(f"Failed to add inundation data to DB for {huc8}-{branch} - ({e})") from e
        
        # If a reference configuration - do things a little diferently.
        elif fim_run_type == 'reference':
            # If no records exist for valid inundation, stop.
            if df_inundation.empty:
                return
            
            # Re-format data for aep tables
            df_inundation = df_inundation.drop(columns=['hand_id', 'rc_stage_ft', 'rc_previous_stage_ft', 'rc_discharge_cfs', 'rc_previous_discharge_cfs', 'prc_method', ])
            df_inundation = df_inundation.rename(columns={"forecast_stage_ft": "fim_stage_ft", "forecast_discharge_cfs": "streamflow_cfs"})
            df_inundation['feature_id_str'] = df_inundation['feature_id'].astype(str)
            df_inundation['hydro_id_str'] = df_inundation['hydro_id'].astype(str)
            df_inundation['huc8'] = huc8
            df_inundation['branch'] = branch
            df_inundation = df_inundation.rename(columns={"index": "oid"})
            
            # print(f"Adding data to {db_fim_table}")# Only process inundation configuration if available data
            try:
                df_inundation.to_postgis(f"{db_table}", con=process_db.engine, schema=db_schema, if_exists='append')
            except Exception as e:
                raise Exception(f"Failed to add inundation data to DB for {huc8}-{branch} - ({e})") from e

    print(f"Successfully processed tif for HUC {huc8} and branch {branch} for {product} for {reference_time}")

def create_inundation_catchment_boundary(huc8, branch):
    """
        Creates the catchment boundary polygons
    """
    catchment_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/gw_catchments_reaches_filtered_addedAttributes_{branch}.tif'
    catchment_url = f"s3://{HAND_BUCKET}/{catchment_key}"

    catchment_dataset = None
    try:
        catchment_dataset = rasterio.open(catchment_url, opener=CACHED_S3)  # open catchment grid from S3  # noqa
    
        # print("--> Setting up mapping array")
        profile = catchment_dataset.profile  # get the rasterio profile so the output can use the profile and match the input  # noqa

        # set the output nodata to 0
        profile['nodata'] = 0
        profile['dtype'] = "int32"

        geoms = []
        windows = riowindows.subdivide(riowindows.Window(0, 0, width=catchment_dataset.width, height=catchment_dataset.height), 1024, 1024)
        for window in windows:
            catchment_window = catchment_dataset.read(window=window)
            ctransform = catchment_dataset.window_transform(window)
            for s, v in shapes(catchment_window, mask=catchment_window!=0, transform=ctransform):
                geoms.append((int(v), shape(s)))
    finally:
        if catchment_dataset is not None:
            catchment_dataset.close()

    # print("Generating polygons")
    crs = 'EPSG:3338' if str(huc8).startswith('19') else 'EPSG:5070'
    df_final = gpd.GeoDataFrame(geoms, columns=['hydro_id', 'geom'], crs=crs, geometry="geom")
    df_final = df_final.dissolve(by="hydro_id")
    df_final = df_final.to_crs(3857)
    df_final = df_final.set_crs('epsg:3857')
    
    if df_final.index.has_duplicates:
        # print("dropping duplicates")
        df_final = df_final.drop_duplicates()
    
    # print("Adding additional metadata columns")
    df_final = df_final.reset_index()
    df_final = df_final.rename(columns={"index": "hydro_id"})
    df_final['fim_version'] = FIM_VERSION
    df_final['model_version'] = f'HAND {HAND_VERSION}'
    df_final['huc8'] = huc8
    df_final['branch'] = branch
                
    return df_final
    

def create_inundation_output(huc8, branch, stage_lookup, reference_time, input_variable, stage_ft_round_up=False):
    """
        Creates the actual inundation output from the stages, catchments, and hand grids
    """
    # join metadata to get path to FIM datasets
    catchment_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/gw_catchments_reaches_filtered_addedAttributes_{branch}.tif'
    hand_key = f'{HAND_PREFIX}/{huc8}/branches/{branch}/rem_zeroed_masked_{branch}.tif'
    
    try:
        print(f"Creating inundation for huc {huc8} and branch {branch}")
        
        hand_dataset = rasterio.open(f's3://{HAND_BUCKET}/{hand_key}', opener=CACHED_S3)  # open HAND grid from S3
        catchment_dataset = rasterio.open(f's3://{HAND_BUCKET}/{catchment_key}', opener=CACHED_S3)  # open catchment grid from S3  # noqa
            
        # print("--> Setting up mapping array")
        catchment_nodata = int(catchment_dataset.nodata)  # get no_data value for catchment raster
        valid_catchments = stage_lookup.index.values # parse lookup to get features with >0 stages  # noqa
        
        # Notable FIM Caching Change: Use the rc_stage_m (upper rating curve table step) for extents when running normal cached workflows (default)
        if stage_ft_round_up:
            stages = stage_lookup['rc_stage_m'].values  # uses the upper rating curve step for the extent
        else:
            stages = stage_lookup['stage_m'].values  # uses the interpolated stage value for the extent

        hydroids = valid_catchments  # Create a feature numpy array from the list

        profile = hand_dataset.profile  # get the rasterio profile so the output can use the profile and match the input  # noqa

        # set the output nodata to 0
        profile['nodata'] = 0
        profile['dtype'] = "int32"

        geoms = []
        windows = riowindows.subdivide(riowindows.Window(0, 0, width=hand_dataset.width, height=hand_dataset.height), 1024, 1024)
        for window in windows:
            catchment_window = catchment_dataset.read(window=window)
            # Only process if there are hydroids with stage >0 in this window
            if not np.isin(catchment_window, valid_catchments).any():
                continue 
            hand_window = hand_dataset.read(window=window)
            results = map_inundation_stages(catchment_window, catchment_nodata,
                                            hand_window, hand_dataset.nodata, hand_dataset.window_transform(window),
                                            hydroids, stages)

            geoms.extend(results)
    finally:
        if hand_dataset is not None:
            hand_dataset.close()

        if catchment_dataset is not None:
            catchment_dataset.close()

    # print("Generating polygons")
    crs = 'EPSG:3338' if str(huc8).startswith('19') else 'EPSG:5070'
    df_final = gpd.GeoDataFrame(geoms, columns=['hydro_id', 'geom'], crs=crs, geometry="geom")
    df_final = df_final.dissolve(by="hydro_id")
    df_final['geom'] = df_final['geom'].simplify(5) #Simplifying polygons to ~5m to clean up problematic geometries
    df_final = df_final.to_crs(3857)
    df_final = df_final.set_crs('epsg:3857')
        
    df_final = df_final.join(stage_lookup).dropna()
    
    if df_final.index.has_duplicates:
        # print("dropping duplicates")
        df_final = df_final.drop_duplicates()
    
    # print("Converting m columns to ft")
    df_final['rc_stage_ft'] = (df_final['rc_stage_m'] * 3.28084).astype(int)
    df_final['rc_previous_stage_ft'] = round(df_final['rc_previous_stage_m'] * 3.28084, 2)
    df_final['rc_discharge_cfs'] = round(df_final['rc_discharge_cms'] * 35.315, 2)
    df_final['rc_previous_discharge_cfs'] = round(df_final['rc_previous_discharge_cms'] * 35.315, 2)
    df_final = df_final.drop(columns=["rc_stage_m", "rc_previous_stage_m", "rc_discharge_cms", "rc_previous_discharge_cms"])
    
    # print("Adding additional metadata columns")
    df_final = df_final.reset_index()
    df_final = df_final.rename(columns={"index": "hydro_id"})
    df_final['fim_version'] = FIM_VERSION
    df_final['model_version'] = f'HAND {HAND_VERSION}'
    df_final['reference_time'] = reference_time
    df_final['forecast_stage_ft'] = round(df_final['stage_m'] * 3.28084, 2)
    df_final['prc_method'] = 'HAND_Processing'
    
    #TODO: Check with Shawn on the whole stage configuration / necessarry changes
    if input_variable == 'stage':
        drop_columns = ['stage_m', 'huc8_branch', 'huc']
    else:
        df_final['max_rc_stage_ft'] = df_final['max_rc_stage_m'] * 3.28084
        df_final['max_rc_stage_ft'] = df_final['max_rc_stage_ft'].astype(int)
        df_final['forecast_discharge_cfs'] = round(df_final['discharge_cms'] * 35.315, 2)
        df_final['max_rc_discharge_cfs'] = round(df_final['max_rc_discharge_cms'] * 35.315, 2)
        drop_columns = ["stage_m", "max_rc_stage_m", "discharge_cms", "max_rc_discharge_cms", ]

    df_final = df_final.drop(columns=drop_columns)
                
    return df_final


def map_inundation_stages(catchment_window, catchment_nodata, hand_window, hand_nodata, hand_transform, hydroids, stages):
    """
        The function will read in the appropriate
        window of the HAND and catchment datasets for main stem and/or full resolution. The stages will
        then be mapped from a numpy array to the catchment window. This will create a windowed stage array.
        The stage array is then compared to the HAND window array to create an inundation array where the
        HAND values are gte to the stage values.

        Each windowed inundation array is then saved to the output array for that specific window that was
        ran.

        For more information on rasterio window processing, see
        https://rasterio.readthedocs.io/en/latest/topics/windowed-rw.html

        If main stem AND full resolution are ran, then the inundation arrays for each configuration will be
        compared and the highest value for each element in the array will be used. This is how we 'merge'
        the two configurations. Because the extents of fr and ms are not the same, we do have to reshape
        the arrays a bit to allow for the comparison
    """
    # If catchment window values exist, then find the max between the stage mapper and the window
    mapping_ar_max = max(hydroids.max(), catchment_window.max())

    # Create a stage mapper that will convert hydroids to their corresponding stage. -9999 is null or
    # no value. we cant use 0 because it will mess up the mapping and use the 0 index
    mapping_ar = np.full(mapping_ar_max+1, -9999, dtype="float32")
    mapping_ar[hydroids] = stages

    # Convert catchment values to 0 where the catchment = catchment_nodata  # noqa
    catchment_window[catchment_window == catchment_nodata] = 0  
    # Convert catchment values to 0 where the HAND = HAND_nodata. This will ensure we are only processing where we have HAND values!  # noqa
    catchment_window[hand_window == hand_nodata] = 0  

    # Convert the catchment to stage
    reclass_window = mapping_ar[catchment_window]

    # Select where stage is gte to HAND
    conditions = reclass_window > hand_window  
    conditions &= reclass_window != -9999

    # Checking to see if there is any inundated areas in the window
    # Because of how inundation_window is constructed, conditions are all non-zero locations.
    results = []
    if not conditions.any():
        return results

    inundation_window = np.where(conditions, catchment_window, 0)
    if inundation_window.max() != 0:
        for s, v in shapes(inundation_window, mask=conditions, transform=hand_transform):
            results.append((int(v), shape(s)))
            
        return results
            

def s3_csv_to_df(bucket, key, columns=None):    
    extra_pd_args = {}
    if columns is not None:
        extra_pd_args['usecols'] = columns
    
    # Read S3 csv file into Pandas DataFrame
    df = pd.read_csv(f"s3://{bucket}/{key}", **extra_pd_args)
    return df

def calculate_stage_values(hydrotable_key, subsetted_streams_bucket, subsetted_streams, huc8_branch):
    """
        Converts discharge (streamflow) values to stage using the rating curve and linear interpolation because rating curve intervals
        
        Arguments:
            local_hydrotable (str): Path to local copy of the branch hydrotable
            df_nwm (DataFrame): A pandas dataframe with columns for feature id and desired discharge column
            
        Returns:
            stage_dict (dict): A dictionary with the hydroid as the key and interpolated stage as the value
    """
    hydrocols = ['HydroID', 'feature_id', 'stage', 'discharge_cms', 'SurfaceArea (m2)']
    df_hydro = s3_csv_to_df(HAND_BUCKET, hydrotable_key, columns=hydrocols)
    df_hydro = df_hydro.rename(columns={'HydroID': 'hydro_id', 'stage': 'stage_m', 'SurfaceArea (m2)': 'surface_area_m2'})

    df_hydro_max = df_hydro.loc[df_hydro.groupby('hydro_id')['stage_m'].idxmax()]
    df_hydro_max = df_hydro_max.set_index('hydro_id')
    df_hydro_max = df_hydro_max[['stage_m', 'discharge_cms']].rename(columns={'stage_m': 'max_rc_stage_m', 'discharge_cms': 'max_rc_discharge_cms'})

    df_forecast = s3_csv_to_df(subsetted_streams_bucket, subsetted_streams)
    df_forecast = df_forecast.loc[df_forecast['huc8_branch']==huc8_branch]
    df_forecast = df_forecast.rename(columns={'streamflow_cms': 'discharge_cms'}) #TODO: Change the output CSV to list discharge instead of streamflow for consistency?
    df_forecast[[
        'stage_m', 
        'rc_stage_m', 
        'rc_previous_stage_m', 
        'rc_discharge_cms', 
        'rc_previous_discharge_cms',
        'flood_area_above_expected_coeff'
    ]] = df_forecast.apply(lambda row : interpolate_stage(row, df_hydro), axis=1).apply(pd.Series)
    
    df_forecast = df_forecast.drop(columns=['huc8_branch', 'huc', 'high_water_threshold'])
    df_forecast = df_forecast.set_index('hydro_id')
    
    # print(f"Removing {len(df_forecast[df_forecast['stage_m'].isna()])} reaches with a NaN interpolated stage")
    df_zero_stage = df_forecast[df_forecast['stage_m'].isna()].copy()
    df_zero_stage['note'] = "NaN Stage After Hydrotable Lookup"
    df_forecast = df_forecast[~df_forecast['stage_m'].isna()]

    stage0 = df_forecast['stage_m'] == 0
    # print(f"Removing {len(df_forecast[stage0])} reaches with a 0 interpolated stage")
    df_zero_stage = pd.concat([df_zero_stage, df_forecast[stage0]], axis=0)
    df_zero_stage['note'] = np.where(df_zero_stage.note.isnull(), "0 Stage After Hydrotable Lookup", "NaN")
    df_forecast = df_forecast[~stage0]

    df_zero_stage = df_zero_stage.drop(columns=['discharge_cms', 'stage_m', 'rc_stage_m', 'rc_previous_stage_m', 'rc_previous_discharge_cms', 'flood_area_above_expected_coeff'])
    df_zero_stage = df_zero_stage.reset_index()
    df_zero_stage = df_zero_stage.drop(columns=['hydro_id','feature_id'])

    df_forecast = df_forecast.join(df_hydro_max)
    # print(f"{len(df_forecast)} reaches will be processed")
     
    return df_forecast, df_zero_stage


def round_m_to_nearest_ft_resolution(value_m, resolution_ft, method="nearest", decimals=4):
    valid_methods = {'up': ceil, 'down': floor, 'nearest': round}
    method = method.lower()
    if method not in valid_methods:
        raise ValueError(f"The method argument must be one of: {', '.join(valid_methods)}")
    value_ft = value_m * 3.28084
    method_func = valid_methods[method]
    rounded_ft = method_func(value_ft / resolution_ft) * resolution_ft
    rounded_m = round(rounded_ft / 3.28084, decimals)
    return rounded_m

def interpolate_stage(df_row, df_hydro):
    ''' 
    Yields both an exactly interpolated stage and a rounded stage based on the CACHE_FIM_RESOLUTION_FT variable.
    The rounded stage is "rounded_stage" here, but ends up being used as "rc_stage_m" everywhere else after being returned.
    '''
    hydro_id = df_row['hydro_id']
    forecast = df_row['discharge_cms']
    high_water_threshold = df_row['high_water_threshold']
    
    hydro_mask = df_hydro.hydro_id == hydro_id
    
    # Filter the hydrotable to this hydroid and pull out discharge and stages into arrays
    subset_hydro = df_hydro.loc[hydro_mask, ['discharge_cms', 'stage_m', 'surface_area_m2']]
    if subset_hydro.empty:
        return np.nan, np.nan, np.nan, np.nan, np.nan, np.nan

    subset_hydro = subset_hydro.sort_values('discharge_cms')
    discharges = subset_hydro['discharge_cms'].values
    stages = subset_hydro['stage_m'].values
    surface_areas_m2 = subset_hydro['surface_area_m2'].values
    
    # Get the interpolated stage by using the discharge forecast value against the arrays
    interpolated_stage = round(np.interp(forecast, discharges, stages), 2)
    forecast_interpolated_surface_area_m2 = round(np.interp(forecast, discharges, surface_areas_m2), 2)
    high_water_interpolated_surface_area_m2 = round(np.interp(high_water_threshold, discharges, surface_areas_m2), 2)
    flood_area_above_expected_coeff = round(forecast_interpolated_surface_area_m2 / high_water_interpolated_surface_area_m2, 2)

    if np.isnan(interpolated_stage):
        print(f"WARNING: Interpolated stage is NaN where hydro_id == {hydro_id}")
        return np.nan, np.nan, np.nan, np.nan, np.nan, np.nan

    # Get the upper and lower values of the 1-ft hydrotable array that the current forecast / interpolated stage is at
    hydrotable_index = np.searchsorted(discharges, forecast, side='right')

    # If streamflow exceeds the rating curve max, just use the max value
    exceeds_max = False
    if hydrotable_index >= len(stages):
        exceeds_max = True
        hydrotable_index = hydrotable_index - 1

    hydrotable_previous_index = hydrotable_index-1
    if CACHE_FIM_RESOLUTION_FT == 1 or exceeds_max:
        # This is a simpler case because this is the resoluation at which the hydrotable is provided
        rounded_stage = stages[hydrotable_index]
        rc_discharge = discharges[hydrotable_index]
        rc_previous_stage = stages[hydrotable_previous_index]
        rc_previous_discharge = discharges[hydrotable_previous_index]
    else:
        rounded_stage = round_m_to_nearest_ft_resolution(interpolated_stage, CACHE_FIM_RESOLUTION_FT, CACHE_FIM_RESOLUTION_ROUNDING)
        rc_discharge = round(np.interp(rounded_stage, stages, discharges), 2)
        rc_previous_stage = max(rounded_stage - CACHE_FIM_RESOLUTION_FT, 0)
        rc_previous_discharge = round(np.interp(rc_previous_stage, stages, discharges), 2)

    return interpolated_stage, rounded_stage, rc_previous_stage, rc_discharge, rc_previous_discharge, flood_area_above_expected_coeff