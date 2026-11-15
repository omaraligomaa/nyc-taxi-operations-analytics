"""Stream the official NYC TLC January 2025 yellow-taxi parquet to SQL Server.

Requires: Python 3.10+, Microsoft ODBC Driver 18 for SQL Server, pip requirements.
Example (Windows, trusted connection):
python src/load_data.py --parquet "data/yellow_tripdata_2025-01.parquet" --zones "data/taxi_zone_lookup.csv" --server "localhost" --replace

--replace explicitly truncates both existing tables before loading. Runs can take time.
"""
from __future__ import annotations
import argparse
import csv
import logging
import math
import os
from pathlib import Path
import pyarrow.parquet as pq
import pyodbc

COLS = [
    ("vendor_id", ["VendorID"]),
    ("pickup_datetime", ["tpep_pickup_datetime"]),
    ("dropoff_datetime", ["tpep_dropoff_datetime"]),
    ("passenger_count", ["passenger_count"]),
    ("trip_distance", ["trip_distance"]),
    ("ratecode_id", ["RatecodeID"]),
    ("store_and_fwd_flag", ["store_and_fwd_flag"]),
    ("pu_location_id", ["PULocationID"]),
    ("do_location_id", ["DOLocationID"]),
    ("payment_type", ["payment_type"]),
    ("fare_amount", ["fare_amount"]),
    ("extra", ["extra"]),
    ("mta_tax", ["mta_tax"]),
    ("tip_amount", ["tip_amount"]),
    ("tolls_amount", ["tolls_amount"]),
    ("improvement_surcharge", ["improvement_surcharge"]),
    ("total_amount", ["total_amount"]),
    ("congestion_surcharge", ["congestion_surcharge"]),
    ("airport_fee", ["Airport_fee", "airport_fee"]),
    ("cbd_congestion_fee", ["cbd_congestion_fee"]),
]

def args_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--parquet', type=Path, required=True)
    p.add_argument('--zones', type=Path, required=True)
    p.add_argument('--server', default=os.getenv('SQL_SERVER','localhost'))
    p.add_argument('--database', default='NYC_Taxi_Analytics')
    p.add_argument('--driver', default='ODBC Driver 18 for SQL Server')
    p.add_argument('--username', default=os.getenv('SQL_USER'))
    p.add_argument('--password', default=os.getenv('SQL_PASSWORD'))
    p.add_argument('--replace', action='store_true', help='DESTROYS existing loaded rows; required for first load into nonempty tables')
    p.add_argument('--batch-size', type=int, default=2000)
    p.add_argument('--max-rows', type=int, default=0, help='Optional test run; 0 means ALL rows')
    p.add_argument('--trust-server-certificate', action='store_true', help='For local development only')
    return p

def safe_value(x):
    if isinstance(x,float) and (math.isnan(x) or math.isinf(x)):
        return None
    return x

def connect(a):
    auth = f'UID={a.username};PWD={a.password}' if a.username else 'Trusted_Connection=yes'
    conn = ('DRIVER={' + a.driver + '};SERVER=' + a.server + ';DATABASE=' + a.database +
            ';Encrypt=yes;TrustServerCertificate=' + ('yes' if a.trust_server_certificate else 'no') + ';' + auth + ';')
    return pyodbc.connect(conn, autocommit=False, timeout=30)

def main():
    a=args_parser().parse_args()
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    if a.batch_size<1 or a.max_rows<0:
        raise SystemExit('batch-size must be >= 1; max-rows must be >= 0')
    for fn in (a.parquet,a.zones):
        if not fn.is_file():
            raise SystemExit(f'File not found: {fn}')
    parquet=pq.ParquetFile(a.parquet)
    available={name.lower():name for name in parquet.schema_arrow.names}
    source_columns=[]
    for target,aliases in COLS:
        actual=next((available[x.lower()] for x in aliases if x.lower() in available),None)
        if actual is None:
            logging.warning('Parquet column absent (loaded as NULL): %s',target)
        source_columns.append(actual)
    mandatory=['pickup_datetime','dropoff_datetime','trip_distance','total_amount','pu_location_id','do_location_id']
    for m in mandatory:
        actual=dict(zip((t for t,_ in COLS),source_columns))[m]
        if actual is None:
            raise SystemExit(f'Missing mandatory column: {m}')
    requested=list(dict.fromkeys(c for c in source_columns if c is not None))
    logging.info('Parquet reported row count: %s',parquet.metadata.num_rows)
    with connect(a) as cn:
        cur=cn.cursor()
        # Explicit replacement prevents double loading when users re-run a completed import.
        existing=cur.execute('SELECT COUNT_BIG(*) FROM dbo.yellow_trips_raw').fetchone()[0]
        existing_zones=cur.execute('SELECT COUNT_BIG(*) FROM dbo.taxi_zones').fetchone()[0]
        if (existing or existing_zones) and not a.replace:
            raise SystemExit(f'Already have {existing} trips and {existing_zones} zones. Re-run with --replace ONLY if you intend to erase and reload.')
        if a.replace:
            cur.execute('TRUNCATE TABLE dbo.yellow_trips_raw')
            cur.execute('DELETE FROM dbo.taxi_zones')
            cn.commit()
        with a.zones.open('r',encoding='utf-8-sig',newline='') as f:
            reader=csv.DictReader(f)
            zones=[]
            for r in reader:
                zones.append((int(r['LocationID']),r.get('Borough'),r.get('Zone'),r.get('service_zone')))
        cur.fast_executemany=True
        cur.executemany('INSERT INTO dbo.taxi_zones (location_id,borough,zone_name,service_zone) VALUES (?,?,?,?)',zones)
        cn.commit()
        logging.info('Imported %s taxi zones',len(zones))
        target_names=[target for target,_ in COLS]
        sql='INSERT INTO dbo.yellow_trips_raw ('+','.join('['+n+']' for n in target_names)+') VALUES ('+','.join('?' for _ in target_names)+')'
        total=0
        for batch in parquet.iter_batches(batch_size=a.batch_size,columns=requested):
            rows=batch.to_pylist()
            payload=[]
            for r in rows:
                if a.max_rows and total + len(payload) >= a.max_rows:
                    break
                payload.append(tuple(safe_value(r.get(s)) if s else None for s in source_columns))
            if payload:
                cur.executemany(sql,payload)
                cn.commit()
                total+=len(payload)
            if total and total%100000 < a.batch_size:
                logging.info('Committed %s trips',total)
            if a.max_rows and total>=a.max_rows:
                break
        db_count=cur.execute('SELECT COUNT_BIG(*) FROM dbo.yellow_trips_raw').fetchone()[0]
        logging.info('DONE: %s trip rows in SQL Server. Run the analyses and reconciliation in NYC Taxi.sql.',db_count)
        if db_count != total:
            raise RuntimeError(f'Row-count discrepancy: sent {total}, database {db_count}')

if __name__=='__main__':
    main()
