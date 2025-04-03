import os
import json
import base64

import sqlalchemy

from botocore.exceptions import ClientError


def get_secret_password(secret_name, region_name, key):
    """
        Gets a password from a sercret stored in AWS secret manager.

        Args:
            secret_name(str): The name of the secret
            region_name(str): The name of the region

        Returns:
            password(str): The text of the password
    """
    import boto3
    # Create a Secrets Manager client
    session = boto3.session.Session()
    client = session.client(
        service_name='secretsmanager',
        region_name=region_name
    )

    # In this sample we only handle the specific exceptions for the 'GetSecretValue' API.
    # See https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html
    # We rethrow the exception by default.

    try:
        get_secret_value_response = client.get_secret_value(
            SecretId=secret_name
        )
    except ClientError as e:
        print(e)
        raise e
    else:
        # Decrypts secret using the associated KMS CMK.
        # Depending on whether the secret is a string or binary, one of these fields will be populated.
        if 'SecretString' in get_secret_value_response:
            secret = get_secret_value_response['SecretString']
            j = json.loads(secret)
            password = j[key]
        else:
            decoded_binary_secret = base64.b64decode(get_secret_value_response['SecretBinary'])
            print("password binary:" + decoded_binary_secret)
            password = decoded_binary_secret.password

        return password


class VizDatabase:
    def __init__(self, db_type):
        self.db_type = db_type.upper()
        self._engine = None

    @property
    def engine(self):
        if self._engine is None:
            self._engine = self._get_db_engine()
        return self._engine
    
    @property
    def connection(self):
        return self.engine.raw_connection()
    
    def close(self):
        if self._engine is not None:
            self._engine.dispose()
            self._engine = None

    def get_db_credentials(self):
        """
        This function pulls database credentials from environment variables.
        It first checks for a password in an environment variable.
        If that doesn't exist, it tries looking or a secret name to query for
        the password using the get_secret_password function.

        Returns:
            db_host (str): The host address of the PostgreSQL database.
            db_name (str): The target database name.
            db_user (str): The database user with write access to authenticate with.
            db_password (str): The password for the db_user.

        """
        db_host = os.environ[f'{self.db_type}_DB_HOST']
        db_name = os.environ[f'{self.db_type}_DB_DATABASE']
        db_user = os.environ[f'{self.db_type}_DB_USERNAME']
        aws_region = os.environ['AWS_REGION']
        try:
            db_password = os.getenv(f'{self.db_type}_DB_PASSWORD')
        except Exception:
            db_password = get_secret_password(os.getenv(f'{self.db_type}_RDS_SECRET_NAME'), aws_region, 'password')
            
        return db_host, db_name, db_user, db_password
    
    def _get_db_engine(self):
        db_host, db_name, db_user, db_password = self.get_db_credentials()
        db_engine = sqlalchemy.create_engine(f'postgresql://{db_user}:{db_password}@{db_host}/{db_name}')
        return db_engine
    
    def query_string(self, query):
        """ Properly escape identifiers in a query """
        with self.engine.connect() as conn:
            qstr = query.as_string(conn.connection.driver_connection)
            return sqlalchemy.text(qstr)
        