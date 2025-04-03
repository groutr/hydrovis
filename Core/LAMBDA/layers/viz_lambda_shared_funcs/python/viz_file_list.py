import re
import isodate
import os
from datetime import datetime, timedelta


def generate_file_list(file_pattern, file_step, file_window, reference_time):
    file_list = []
    if 'common/data/model/com/nwm/prod' in file_pattern and (datetime.today() - timedelta(29)) > reference_time:
        file_pattern = file_pattern.replace('common/data/model/com/nwm/prod', 'https://storage.googleapis.com/national-water-model')

    if file_window:
        if not file_step:
            raise ValueError("file_window and file_step must be specified together")
        start = reference_time - isodate.parse_duration(file_window)
        reference_dates = list(date_range(start, reference_time, isodate.parse_duration(file_step)))
    else:
        reference_dates = [reference_time]

    token_dict = get_file_tokens(file_pattern)

    for reference_date in reference_dates:
        reference_date_files = get_formatted_files(file_pattern, token_dict, reference_date)
        file_list.extend(reference_date_files)
        
    return file_list


def date_range(start, stop, step):
    assert start < stop and start + step > start
    while start + step <= stop:
        yield start
        start += step
        

def get_file_tokens(file_pattern):
    tokens = re.findall("{{(?P<key>[a-z]+):(?P<value>[^{]+)}}", file_pattern)
    token_dict = {'datetime': [], 'range': [], 'variable': []}
    for (key, value) in tokens:
        token_dict[key].append(value)
    return token_dict


def get_formatted_files(file_pattern, token_dict, reference_date):
    reference_date_file = file_pattern
    reference_date_files = []
    for variable_token in token_dict['variable']:
        reference_date_file = parse_variable_token_value(reference_date_file, variable_token)
        
    for datetime_token in token_dict['datetime']:
        reference_date_file = parse_datetime_token_value(reference_date_file, reference_date, datetime_token)

    if token_dict['range']:
        unique_range_tokens = list(set(token_dict['range']))
        for range_token in unique_range_tokens:
            reference_date_files = parse_range_token_value(reference_date_file, range_token, existing_list=reference_date_files)
    else:
        reference_date_files = [reference_date_file]
        
    return reference_date_files


def parse_datetime_token_value(input_file, reference_date, datetime_token):
    og_datetime_token = datetime_token
    if "reftime" in datetime_token:
        reftime = datetime_token.split(",")[0].replace("reftime", "")
        datetime_token = datetime_token.split(",")[-1].replace(" ","")
        arithmetic = reftime[0]
        date_delta_value = int(reftime[1:][:-1])
        date_delta = reftime[1:][-1]

        if date_delta.upper() == "M":
            date_delta = datetime.timedelta(minutes=date_delta_value)
        elif date_delta.upper() == "H":
            date_delta = datetime.timedelta(hours=date_delta_value)
        elif date_delta.upper() == "D":
            date_delta = datetime.timedelta(days=date_delta_value)
        else:
            raise Exception("timedelta is only configured for minutes, hours, and days")

        if arithmetic == "+":
            reference_date = reference_date + date_delta
        else:
            reference_date = reference_date - date_delta

    datetime_value = reference_date.strftime(datetime_token)
    new_input_file = input_file.replace(f"{{{{datetime:{og_datetime_token}}}}}", datetime_value)

    return new_input_file


def parse_variable_token_value(input_file, variable_token):
    variable_value = os.environ[variable_token]
    new_input_file = input_file.replace(f"{{{{variable:{variable_token}}}}}", variable_value)

    return new_input_file


def parse_range_token_value(reference_date_file, range_token, existing_list = []):
    range_min = 0
    range_step = 1
    number_format = '%01d'

    parts = range_token.split(',')
    num_parts = len(parts)

    if num_parts == 1:
        range_max = parts[0]
    elif num_parts == 2:
        range_min, range_max = parts
    elif num_parts == 3:
        range_min, range_max, range_step = parts
    elif num_parts == 4:
        range_min, range_max, range_step, number_format = parts
    else:
        raise ValueError("Invalid Token Used")

    try:
        range_min = int(range_min)
        range_max = int(range_max)
        range_step = int(range_step)
    except ValueError:
        raise ValueError("Ranges must be integers")

    new_input_files = []
    if existing_list == []:
        existing_list = [reference_date_file]
    
    for item in existing_list:
        for i in range(range_min, range_max, range_step):
            range_value = number_format % i
            new_input_file = item.replace(f"{{{{range:{range_token}}}}}", range_value)
            new_input_files.append(new_input_file)

    return new_input_files
