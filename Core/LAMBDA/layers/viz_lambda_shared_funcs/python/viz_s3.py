import re
from datetime import datetime, timedelta

import fsspec


def s3_full(bucket, file):
    """Convenience function to construct a fully qualified
    s3 url.
    """
    return f"s3://{bucket}/{file}"


def check_exists(uri):
    fs = fsspec.filesystem('s3')
    return fs.exists(uri)


def check_file_source(bucket, file):
    """Check if file exists on S3 with fallback to http"""
    http = fsspec.filesystem('https')
    if file.startswith('http'):
        if http.exists(file):
            return file
    else:
        sfile = s3_full(bucket, file)
        if check_exists(sfile):
            return sfile
        elif '/prod' in file:
            date_metadata = re.findall(r"(\d{8})/[a-z0-9_]*/nwm.t(\d{2})z.*[ftm](\d{1,9})\.", file)
            date = date_metadata[0][0]
            initialize_hour = date_metadata[0][1]
            delta_hour = date_metadata[0][2]

            model_initialization_datetime = datetime.strptime(f"{date}{initialize_hour}", "%Y%m%d%H")
            forecast_datetime = model_initialization_datetime + timedelta(hours=int(delta_hour))
            forecast_date = forecast_datetime.strftime("%Y")
            forecast_date_hour = forecast_datetime.strftime("%Y%m%d%H")
            
            google_file = file.replace('common/data/model/com/nwm/prod', 'https://storage.googleapis.com/national-water-model')
            if http.exists(google_file):
                return google_file
            else:
                if "channel" in file:
                    retro_file = f"https://noaa-nwm-retrospective-2-1-pds.s3.amazonaws.com/model_output/{forecast_date}/{forecast_date_hour}00.CHRTOUT_DOMAIN1.comp"
                else:
                    retro_file = f"https://noaa-nwm-retrospective-2-1-pds.s3.amazonaws.com/forcing/{forecast_date}/{forecast_date_hour}00.LDASIN_DOMAIN1.comp"

                if http.exists(retro_file):
                    return retro_file

