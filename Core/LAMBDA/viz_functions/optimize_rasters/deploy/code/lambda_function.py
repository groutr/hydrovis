import pathlib
import fnmatch
import fsspec
import subprocess
import tempfile

from osgeo import gdal

s3_sse = fsspec.filesystem('s3', s3_additional_kwargs={'ServerSideEncryption': 'aws:kms'})

def lambda_handler(event, context):
    """
        The lambda handler is the function that is kicked off with the lambda. This function will download a inundation
        tif and convert it to mrf. The mrf will then be uploaded to S3

        Args:
            event(event object): An event is a JSON-formatted document that contains data for a Lambda function to
                                 process
            context(object): Provides methods and properties that provide information about the invocation, function,
                             and runtime environment
    """
    if 'step' in event and event['step'] == 'create_vrt':
        run_create_vrt(event)
    else:
        run_optimize_raster(event)

def create_optimized_raster(input_raster, output_raster):
    args = ["gdal_translate", "-q", "-strict", "-co", "UNIFORM_SCALE=4", "-co", "COMPRESS=DEFLATE"]
    io_args = ["-of", "MRF", input_raster, output_raster]

    try:
        rv = subprocess.run(args + io_args, capture_output=True, check=True)
    except subprocess.CalledProcessError as e:
        print("Conversion Failed:", e.cmd, e.returncode, e.output)

def run_optimize_raster(event):
    # Parse the event to get the necessary arguments
    input_raster_bucket = event['output_bucket']
    input_raster_key = event['output_raster']

    output_raster_bucket = input_raster_bucket
    output_raster_key = input_raster_key.replace("/tif/", "/mrf/")
    output_raster_prefix = os.path.dirname(output_raster_key)

    vsi_input = f"/vsis3/{input_raster_bucket}/{input_raster_key}"
    tmp_output = pathlib.Path(tempfile.mkdtemp())

    print(f"Converting {vsi_input} into {tmp_output}")
    create_optimized_raster(vsi_input, tmp_output)
    
    # Loop through the mrf files (4) and upload them to S3
    for mrf_file in tmp_output.iterdir():
        S3_file_path = f"s3://{output_raster_bucket}/{output_raster_prefix}/{mrf_file.name}
        print(f"Writing {S3_file_path}")
        s3_sse.put(mrf_file, S3_file_path)
        mrf_file.unlink()
    
    # Remove temp directory
    tmp_output.rmdir()

def run_create_vrt(event):
    fim_config = event['args']['fim_config']['name']
    output_bucket = event['args']['product']['raster_outputs']['output_bucket']
    output_workspaces = event['args']['product']['raster_outputs']['output_raster_workspaces']
    output_workspace = next(list(workspace.values())[0] for workspace in output_workspaces if list(workspace.keys())[0] == fim_config)

    # We only create two VRTs (one in the mrf folder and another in the tif folder)
    # because we only want one in the mrf folder, but for it to be moved to the 
    # publish folder it has to also exist in the tif folder since the tif folder
    # is used as the basis for what gets copied over in the viz_update_egis_data lambda
    create_vrt(output_bucket, f'{output_workspace}/tif/', '.tif')

def create_vrt(output_bucket, output_workspace, extension):
    s3_client = boto3.client('s3')
    paginator = s3_client.get_paginator('list_objects')
    operation_parameters = {'Bucket': output_bucket,
                            'Prefix': output_workspace,
                            'Delimiter': '/'}
    page_iterator = paginator.paginate(**operation_parameters)
    vrt_files = []
    page_count = 0
    for page in page_iterator:
        page_count += 1
        objects = page['Contents']
        for obj in objects:
            key = obj['Key']
            if key.endswith(extension):
                vrt_files.append(f'/vsis3/{output_bucket}/{key}')

    out_vrt = f'/vsis3/{output_bucket}/{output_workspace}_dataset.vrt'
    print(f"Building VRT from {len(vrt_files)} files and writing to {out_vrt}...")
    vrt_options = gdal.BuildVRTOptions(VRTNodata=0)
    gdal.BuildVRT(out_vrt, vrt_files, options=vrt_options)
