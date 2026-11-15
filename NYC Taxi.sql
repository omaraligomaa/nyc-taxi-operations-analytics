USE master;
GO

IF DB_ID('NYC_Taxi_Analytics') IS NULL
BEGIN
    CREATE DATABASE NYC_Taxi_Analytics;
END;
GO

USE NYC_Taxi_Analytics;
GO

CREATE SCHEMA staging;
GO

CREATE SCHEMA analytics;
GO

SELECT
    DB_NAME() AS DatabaseName,
    name AS SchemaName
FROM sys.schemas
WHERE name IN ('staging', 'analytics');


USE NYC_Taxi_Analytics;
GO

-- Taxi Zones Reference Table
IF OBJECT_ID('dbo.taxi_zones', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.taxi_zones (
        location_id INT NOT NULL PRIMARY KEY,
        borough NVARCHAR(100),
        zone_name NVARCHAR(200),
        service_zone NVARCHAR(100)
    );
END;
GO

-- Yellow Taxi Trip Records
IF OBJECT_ID('dbo.yellow_trips_raw', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.yellow_trips_raw (
        trip_id BIGINT IDENTITY(1,1) PRIMARY KEY,
        vendor_id INT,
        pickup_datetime DATETIME2(0),
        dropoff_datetime DATETIME2(0),
        passenger_count FLOAT,
        trip_distance FLOAT,
        ratecode_id FLOAT,
        store_and_fwd_flag NVARCHAR(8),
        pu_location_id INT,
        do_location_id INT,
        payment_type INT,
        fare_amount FLOAT,
        extra FLOAT,
        mta_tax FLOAT,
        tip_amount FLOAT,
        tolls_amount FLOAT,
        improvement_surcharge FLOAT,
        total_amount FLOAT,
        congestion_surcharge FLOAT,
        airport_fee FLOAT,
        cbd_congestion_fee FLOAT
    );
END;
GO

USE NYC_Taxi_Analytics;
GO

SELECT COUNT(*) AS TotalTrips
FROM dbo.yellow_trips_raw;

SELECT COUNT(*) AS TotalZones
FROM dbo.taxi_zones;

USE NYC_Taxi_Analytics;
GO

-- Analysis: Data Quality Assessment

SELECT
    COUNT_BIG(*) AS TotalTrips,

    SUM(CASE
        WHEN pickup_datetime IS NULL
          OR dropoff_datetime IS NULL
        THEN 1 ELSE 0
    END) AS MissingDates,

    SUM(CASE
        WHEN dropoff_datetime <= pickup_datetime
        THEN 1 ELSE 0
    END) AS InvalidDuration,

    SUM(CASE
        WHEN trip_distance IS NULL
          OR trip_distance <= 0
        THEN 1 ELSE 0
    END) AS InvalidDistance,

    SUM(CASE
        WHEN total_amount IS NULL
          OR total_amount < 0
        THEN 1 ELSE 0
    END) AS InvalidAmount,

    SUM(CASE
        WHEN pu_location_id IS NULL
          OR do_location_id IS NULL
        THEN 1 ELSE 0
    END) AS MissingLocations,

    SUM(CASE
        WHEN pickup_datetime >= '2025-01-01'
         AND pickup_datetime < '2025-02-01'
        THEN 1 ELSE 0
    END) AS JanuaryTrips

FROM dbo.yellow_trips_raw;

-- Analysis: Valid Trips & Data Quality Rate

USE NYC_Taxi_Analytics;
GO

WITH TripValidation AS (
    SELECT
        trip_id,
        CASE
            WHEN pickup_datetime >= '2025-01-01'
             AND pickup_datetime < '2025-02-01'
             AND dropoff_datetime > pickup_datetime
             AND trip_distance > 0
             AND total_amount > 0
             AND pu_location_id IS NOT NULL
             AND do_location_id IS NOT NULL
            THEN 1
            ELSE 0
        END AS IsValid
    FROM dbo.yellow_trips_raw
)

SELECT
    COUNT_BIG(*) AS TotalTrips,

    SUM(CAST(IsValid AS BIGINT)) AS ValidTrips,

    SUM(CAST(1 - IsValid AS BIGINT)) AS ExcludedTrips,

    CAST(
        100.0 * SUM(CAST(IsValid AS BIGINT))
        / NULLIF(COUNT_BIG(*), 0)
        AS DECIMAL(5,2)
    ) AS ValidTripsPercentage

FROM TripValidation;

-- KPI: Revenue Summary

USE NYC_Taxi_Analytics;
GO

WITH ValidTrips AS (
    SELECT
        fare_amount,
        total_amount,
        tip_amount,
        trip_distance
    FROM dbo.yellow_trips_raw
    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
)
SELECT
    COUNT_BIG(*) AS TotalValidTrips,
    CAST(SUM(total_amount) AS DECIMAL(18,2))
        AS TotalPassengerCharges,
    CAST(SUM(fare_amount) AS DECIMAL(18,2))
        AS TotalFareAmount,
    CAST(AVG(total_amount) AS DECIMAL(18,2))
        AS AvgTripCharge,
    CAST(AVG(fare_amount) AS DECIMAL(18,2))
        AS AvgFare,
    CAST(AVG(tip_amount) AS DECIMAL(18,2))
        AS AvgRecordedTip,
    CAST(AVG(trip_distance) AS DECIMAL(18,2))
        AS AvgTripDistanceMiles
FROM ValidTrips;

-- Analysis: Daily Revenue Trends

USE NYC_Taxi_Analytics;
GO

WITH DailyRevenue AS (
    SELECT
        CAST(pickup_datetime AS DATE) AS TripDate,
        COUNT_BIG(*) AS TotalTrips,
        SUM(total_amount) AS TotalPassengerCharges
    FROM dbo.yellow_trips_raw
    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
    GROUP BY CAST(pickup_datetime AS DATE)
),
RevenueComparison AS (
    SELECT
        TripDate,
        TotalTrips,
        TotalPassengerCharges,
        LAG(TotalPassengerCharges) OVER (
            ORDER BY TripDate
        ) AS PreviousDayCharges
    FROM DailyRevenue
)
SELECT
    TripDate,
    TotalTrips,
    CAST(TotalPassengerCharges AS DECIMAL(18,2))
        AS TotalPassengerCharges,
    CAST(
        100.0 * (
            TotalPassengerCharges - PreviousDayCharges
        ) / NULLIF(PreviousDayCharges, 0)
        AS DECIMAL(10,2)
    ) AS DailyChangePct
FROM RevenueComparison
ORDER BY TripDate;

-- Analysis: Weekday Performance

WITH DailyPerformance AS (
    SELECT
        CAST(pickup_datetime AS DATE) AS TripDate,
        COUNT_BIG(*) AS TotalTrips,
        SUM(total_amount) AS TotalCharges
    FROM dbo.yellow_trips_raw
    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
    GROUP BY CAST(pickup_datetime AS DATE)
),
WeekdayPerformance AS (
    SELECT
        DATENAME(WEEKDAY, TripDate) AS DayName,
        (DATEDIFF(DAY, '19000101', TripDate) % 7) + 1 AS DayNumber,
        TotalTrips,
        TotalCharges
    FROM DailyPerformance
)
SELECT
    DayName,
    COUNT(*) AS DaysInMonth,
    SUM(TotalTrips) AS TotalTrips,
    CAST(AVG(CAST(TotalTrips AS FLOAT))
        AS DECIMAL(18,0)) AS AvgDailyTrips,
    CAST(SUM(TotalCharges)
        AS DECIMAL(18,2)) AS TotalCharges,
    CAST(AVG(TotalCharges)
        AS DECIMAL(18,2)) AS AvgDailyCharges
FROM WeekdayPerformance
GROUP BY DayName, DayNumber
ORDER BY DayNumber;

-- Analysis: Peak Hours Performance

USE NYC_Taxi_Analytics;
GO

WITH HourlyDemand AS (
    SELECT
        DATEPART(HOUR, pickup_datetime) AS PickupHour,
        COUNT_BIG(*) AS TotalTrips,
        SUM(total_amount) AS TotalPassengerCharges
    FROM dbo.yellow_trips_raw
    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
    GROUP BY DATEPART(HOUR, pickup_datetime)
)
SELECT
    PickupHour,
    TotalTrips,
    CAST(
        TotalTrips / 31.0
        AS DECIMAL(18,0)
    ) AS AvgDailyTrips,
    CAST(
        TotalPassengerCharges
        AS DECIMAL(18,2)
    ) AS TotalPassengerCharges,
    DENSE_RANK() OVER (
        ORDER BY TotalTrips DESC
    ) AS DemandRank
FROM HourlyDemand
ORDER BY PickupHour;

-- Analysis: Top Pickup Zones Performance

USE NYC_Taxi_Analytics;
GO

WITH ZonePerformance AS (
    SELECT
        z.borough AS Borough,
        z.zone_name AS PickupZone,
        COUNT_BIG(*) AS TotalTrips,
        SUM(t.total_amount) AS TotalPassengerCharges
    FROM dbo.yellow_trips_raw AS t
    INNER JOIN dbo.taxi_zones AS z
        ON t.pu_location_id = z.location_id
    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0
      AND t.pu_location_id IS NOT NULL
      AND t.do_location_id IS NOT NULL
    GROUP BY
        z.borough,
        z.zone_name
),
RankedZones AS (
    SELECT
        Borough,
        PickupZone,
        TotalTrips,
        TotalPassengerCharges,
        DENSE_RANK() OVER (
            ORDER BY TotalTrips DESC
        ) AS DemandRank
    FROM ZonePerformance
)
SELECT TOP (10)
    Borough,
    PickupZone,
    TotalTrips,
    CAST(
        TotalPassengerCharges AS DECIMAL(18,2)
    ) AS TotalPassengerCharges,
    DemandRank
FROM RankedZones
ORDER BY DemandRank, PickupZone;

-- Analysis: Top Pickup Zones by Passenger Charges

USE NYC_Taxi_Analytics;
GO

WITH ZoneCharges AS (
    SELECT
        z.borough AS Borough,
        z.zone_name AS PickupZone,
        COUNT_BIG(*) AS TotalTrips,
        SUM(t.total_amount) AS TotalPassengerCharges,
        AVG(t.total_amount) AS AvgTripCharge
    FROM dbo.yellow_trips_raw AS t
    INNER JOIN dbo.taxi_zones AS z
        ON t.pu_location_id = z.location_id
    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0
      AND t.pu_location_id IS NOT NULL
      AND t.do_location_id IS NOT NULL
    GROUP BY
        z.borough,
        z.zone_name
)
SELECT TOP (10)
    Borough,
    PickupZone,
    TotalTrips,
    CAST(TotalPassengerCharges AS DECIMAL(18,2))
        AS TotalPassengerCharges,
    CAST(AvgTripCharge AS DECIMAL(18,2))
        AS AvgTripCharge,
    DENSE_RANK() OVER (
        ORDER BY TotalPassengerCharges DESC
    ) AS ChargesRank
FROM ZoneCharges
ORDER BY ChargesRank, PickupZone;

-- Analysis: Airport vs Non-Airport Trip Performance

USE NYC_Taxi_Analytics;
GO

WITH TripSegments AS (
    SELECT
        CASE
            WHEN z.zone_name IN (
                'JFK Airport',
                'LaGuardia Airport'
            )
            THEN 'Airport'
            ELSE 'Non-Airport'
        END AS TripCategory,

        t.total_amount,
        t.fare_amount,
        t.trip_distance,

        DATEDIFF(
            SECOND,
            t.pickup_datetime,
            t.dropoff_datetime
        ) / 60.0 AS TripDurationMinutes

    FROM dbo.yellow_trips_raw AS t

    INNER JOIN dbo.taxi_zones AS z
        ON t.pu_location_id = z.location_id

    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0
      AND t.pu_location_id IS NOT NULL
      AND t.do_location_id IS NOT NULL
)

SELECT
    TripCategory,

    COUNT_BIG(*) AS TotalTrips,

    CAST(
        SUM(total_amount) AS DECIMAL(18,2)
    ) AS TotalPassengerCharges,

    CAST(
        AVG(total_amount) AS DECIMAL(18,2)
    ) AS AvgTripCharge,

    CAST(
        AVG(fare_amount) AS DECIMAL(18,2)
    ) AS AvgFare,

    CAST(
        AVG(trip_distance) AS DECIMAL(18,2)
    ) AS AvgDistanceMiles,

    CAST(
        AVG(TripDurationMinutes) AS DECIMAL(18,2)
    ) AS AvgDurationMinutes

FROM TripSegments

GROUP BY TripCategory

ORDER BY TotalPassengerCharges DESC;

-- Analysis: Airport Fare & Surcharge Breakdown

USE NYC_Taxi_Analytics;
GO

WITH TripSegments AS (
    SELECT
        CASE
            WHEN z.zone_name IN (
                'JFK Airport',
                'LaGuardia Airport'
            )
            THEN 'Airport'
            ELSE 'Non-Airport'
        END AS TripCategory,

        t.total_amount,
        t.fare_amount,
        t.tip_amount,
        t.airport_fee,
        t.congestion_surcharge,
        t.cbd_congestion_fee,
        t.tolls_amount

    FROM dbo.yellow_trips_raw AS t

    INNER JOIN dbo.taxi_zones AS z
        ON t.pu_location_id = z.location_id

    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0
      AND t.pu_location_id IS NOT NULL
      AND t.do_location_id IS NOT NULL
)

SELECT
    TripCategory,

    COUNT_BIG(*) AS TotalTrips,

    CAST(AVG(total_amount) AS DECIMAL(18,2))
        AS AvgTripCharge,

    CAST(AVG(fare_amount) AS DECIMAL(18,2))
        AS AvgFare,

    CAST(AVG(COALESCE(tip_amount, 0)) AS DECIMAL(18,2))
        AS AvgTip,

    CAST(AVG(COALESCE(airport_fee, 0)) AS DECIMAL(18,2))
        AS AvgAirportFee,

    CAST(AVG(COALESCE(congestion_surcharge, 0)) AS DECIMAL(18,2))
        AS AvgCongestionSurcharge,

    CAST(AVG(COALESCE(cbd_congestion_fee, 0)) AS DECIMAL(18,2))
        AS AvgCBDCongestionFee,

    CAST(AVG(COALESCE(tolls_amount, 0)) AS DECIMAL(18,2))
        AS AvgTolls

FROM TripSegments
GROUP BY TripCategory
ORDER BY AvgTripCharge DESC;


-- Analysis: Trip Distance & Duration Performance

USE NYC_Taxi_Analytics;
GO

WITH TripSegments AS (
    SELECT
        CASE
            WHEN trip_distance < 2 THEN '0-2 Miles'
            WHEN trip_distance < 5 THEN '2-5 Miles'
            WHEN trip_distance < 10 THEN '5-10 Miles'
            WHEN trip_distance < 20 THEN '10-20 Miles'
            ELSE '20+ Miles'
        END AS DistanceCategory,

        CASE
            WHEN trip_distance < 2 THEN 1
            WHEN trip_distance < 5 THEN 2
            WHEN trip_distance < 10 THEN 3
            WHEN trip_distance < 20 THEN 4
            ELSE 5
        END AS CategoryOrder,

        trip_distance,
        total_amount,

        DATEDIFF(
            SECOND,
            pickup_datetime,
            dropoff_datetime
        ) / 60.0 AS DurationMinutes

    FROM dbo.yellow_trips_raw

    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
)

SELECT
    DistanceCategory,
    COUNT_BIG(*) AS TotalTrips,

    CAST(
        100.0 * COUNT_BIG(*) /
        NULLIF(SUM(COUNT_BIG(*)) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS TripSharePct,

    CAST(AVG(trip_distance) AS DECIMAL(18,2))
        AS AvgDistanceMiles,

    CAST(AVG(DurationMinutes) AS DECIMAL(18,2))
        AS AvgDurationMinutes,

    CAST(AVG(total_amount) AS DECIMAL(18,2))
        AS AvgTripCharge,

    CAST(SUM(total_amount) AS DECIMAL(18,2))
        AS TotalPassengerCharges

FROM TripSegments

GROUP BY
    DistanceCategory,
    CategoryOrder

ORDER BY CategoryOrder;


-- Analysis: Trip Distance Outlier Investigation

USE NYC_Taxi_Analytics;
GO

SELECT
    COUNT_BIG(*) AS TotalValidTrips,

    SUM(CASE
        WHEN trip_distance > 50
        THEN 1 ELSE 0
    END) AS TripsOver50Miles,

    SUM(CASE
        WHEN trip_distance > 100
        THEN 1 ELSE 0
    END) AS TripsOver100Miles,

    SUM(CASE
        WHEN trip_distance > 500
        THEN 1 ELSE 0
    END) AS TripsOver500Miles,

    CAST(
        AVG(trip_distance)
        AS DECIMAL(18,2)
    ) AS AvgDistance,

    CAST(
        MAX(trip_distance)
        AS DECIMAL(18,2)
    ) AS MaxDistance,

    CAST(
        MAX(
            DATEDIFF_BIG(
                SECOND,
                pickup_datetime,
                dropoff_datetime
            ) / 60.0
        )
        AS DECIMAL(18,2)
    ) AS MaxDurationMinutes

FROM dbo.yellow_trips_raw

WHERE pickup_datetime >= '2025-01-01'
  AND pickup_datetime < '2025-02-01'
  AND dropoff_datetime > pickup_datetime
  AND trip_distance > 0
  AND total_amount > 0
  AND pu_location_id IS NOT NULL
  AND do_location_id IS NOT NULL;


  -- Analysis: Extreme Trip Distance Investigation

USE NYC_Taxi_Analytics;
GO

SELECT TOP (15)
    trip_id,
    pickup_datetime,
    dropoff_datetime,

    CAST(trip_distance AS DECIMAL(18,2))
        AS TripDistanceMiles,

    CAST(
        DATEDIFF_BIG(
            SECOND,
            pickup_datetime,
            dropoff_datetime
        ) / 60.0
        AS DECIMAL(18,2)
    ) AS DurationMinutes,

    CAST(
        trip_distance /
        NULLIF(
            DATEDIFF_BIG(
                SECOND,
                pickup_datetime,
                dropoff_datetime
            ) / 3600.0,
            0
        )
        AS DECIMAL(18,2)
    ) AS EstimatedSpeedMPH,

    CAST(total_amount AS DECIMAL(18,2))
        AS TotalPassengerCharges

FROM dbo.yellow_trips_raw

WHERE pickup_datetime >= '2025-01-01'
  AND pickup_datetime < '2025-02-01'
  AND dropoff_datetime > pickup_datetime
  AND trip_distance > 0
  AND total_amount > 0

ORDER BY trip_distance DESC;


-- Analysis: Operational Efficiency & Speed

USE NYC_Taxi_Analytics;
GO

WITH TripMetrics AS (
    SELECT
        trip_distance,
        total_amount,

        DATEDIFF_BIG(
            SECOND,
            pickup_datetime,
            dropoff_datetime
        ) / 60.0 AS DurationMinutes,

        trip_distance /
        NULLIF(
            DATEDIFF_BIG(
                SECOND,
                pickup_datetime,
                dropoff_datetime
            ) / 3600.0,
            0
        ) AS EstimatedSpeedMPH

    FROM dbo.yellow_trips_raw

    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
),
OperationalTrips AS (
    SELECT *
    FROM TripMetrics

    WHERE DurationMinutes BETWEEN 1 AND 180
      AND trip_distance <= 100
      AND EstimatedSpeedMPH <= 80
)
SELECT
    COUNT_BIG(*) AS OperationalTrips,

    CAST(AVG(trip_distance) AS DECIMAL(18,2))
        AS AvgDistanceMiles,

    CAST(AVG(DurationMinutes) AS DECIMAL(18,2))
        AS AvgDurationMinutes,

    CAST(AVG(EstimatedSpeedMPH) AS DECIMAL(18,2))
        AS AvgEstimatedSpeedMPH,

    CAST(AVG(total_amount) AS DECIMAL(18,2))
        AS AvgTripCharge

FROM OperationalTrips;


-- Analysis: Payment Methods & Tipping Performance

USE NYC_Taxi_Analytics;
GO

WITH PaymentAnalysis AS (
    SELECT
        CASE payment_type
            WHEN 0 THEN 'Flex Fare'
            WHEN 1 THEN 'Credit Card'
            WHEN 2 THEN 'Cash'
            WHEN 3 THEN 'No Charge'
            WHEN 4 THEN 'Dispute'
            WHEN 5 THEN 'Unknown'
            WHEN 6 THEN 'Voided Trip'
            ELSE 'Other / Missing'
        END AS PaymentMethod,

        fare_amount,
        tip_amount,
        total_amount

    FROM dbo.yellow_trips_raw

    WHERE pickup_datetime >= '2025-01-01'
      AND pickup_datetime < '2025-02-01'
      AND dropoff_datetime > pickup_datetime
      AND trip_distance > 0
      AND total_amount > 0
      AND pu_location_id IS NOT NULL
      AND do_location_id IS NOT NULL
),
PaymentSummary AS (
    SELECT
        PaymentMethod,
        COUNT_BIG(*) AS TotalTrips,

        SUM(total_amount) AS TotalPassengerCharges,

        AVG(total_amount) AS AvgTripCharge,

        AVG(COALESCE(tip_amount, 0)) AS AvgRecordedTip,

        SUM(
            CASE WHEN tip_amount > 0
                 THEN 1 ELSE 0 END
        ) AS TripsWithRecordedTip

    FROM PaymentAnalysis
    GROUP BY PaymentMethod
)
SELECT
    PaymentMethod,
    TotalTrips,

    CAST(
        100.0 * TotalTrips /
        NULLIF(SUM(TotalTrips) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS TripSharePct,

    CAST(TotalPassengerCharges AS DECIMAL(18,2))
        AS TotalPassengerCharges,

    CAST(AvgTripCharge AS DECIMAL(18,2))
        AS AvgTripCharge,

    CAST(AvgRecordedTip AS DECIMAL(18,2))
        AS AvgRecordedTip,

    CAST(
        100.0 * TripsWithRecordedTip /
        NULLIF(TotalTrips, 0)
        AS DECIMAL(10,2)
    ) AS RecordedTipRatePct

FROM PaymentSummary
ORDER BY TotalTrips DESC;

-- Analysis: Payment Type Data Quality Investigation

USE NYC_Taxi_Analytics;
GO

SELECT
    payment_type AS PaymentCode,
    COUNT_BIG(*) AS TotalTrips,

    CAST(
        100.0 * COUNT_BIG(*) /
        SUM(COUNT_BIG(*)) OVER ()
        AS DECIMAL(10,2)
    ) AS TripSharePct

FROM dbo.yellow_trips_raw

WHERE pickup_datetime >= '2025-01-01'
  AND pickup_datetime < '2025-02-01'
  AND dropoff_datetime > pickup_datetime
  AND trip_distance > 0
  AND total_amount > 0
  AND pu_location_id IS NOT NULL
  AND do_location_id IS NOT NULL

GROUP BY payment_type
ORDER BY TotalTrips DESC;

-- Analysis: Top Pickup-to-Dropoff Routes

USE NYC_Taxi_Analytics;
GO

WITH RoutePerformance AS (
    SELECT
        t.pu_location_id,
        t.do_location_id,

        pz.borough AS PickupBorough,
        pz.zone_name AS PickupZone,

        dz.borough AS DropoffBorough,
        dz.zone_name AS DropoffZone,

        COUNT_BIG(*) AS TotalTrips,
        SUM(t.total_amount) AS TotalPassengerCharges,
        AVG(t.total_amount) AS AvgTripCharge,
        AVG(t.trip_distance) AS AvgTripDistance

    FROM dbo.yellow_trips_raw AS t

    INNER JOIN dbo.taxi_zones AS pz
        ON t.pu_location_id = pz.location_id

    INNER JOIN dbo.taxi_zones AS dz
        ON t.do_location_id = dz.location_id

    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0

    GROUP BY
        t.pu_location_id,
        t.do_location_id,
        pz.borough,
        pz.zone_name,
        dz.borough,
        dz.zone_name
),
RankedRoutes AS (
    SELECT
        *,
        DENSE_RANK() OVER (
            ORDER BY TotalTrips DESC
        ) AS DemandRank
    FROM RoutePerformance
)

SELECT TOP (10)
    PickupBorough,
    PickupZone,
    DropoffBorough,
    DropoffZone,
    TotalTrips,

    CAST(
        TotalPassengerCharges AS DECIMAL(18,2)
    ) AS TotalPassengerCharges,

    CAST(
        AvgTripCharge AS DECIMAL(18,2)
    ) AS AvgTripCharge,

    CAST(
        AvgTripDistance AS DECIMAL(18,2)
    ) AS AvgTripDistanceMiles,

    DemandRank

FROM RankedRoutes

ORDER BY
    DemandRank,
    pu_location_id,
    do_location_id;

    -- Analysis: Borough Demand & Revenue Ranking

USE NYC_Taxi_Analytics;
GO

WITH BoroughPerformance AS (
    SELECT
        z.borough AS PickupBorough,

        COUNT_BIG(*) AS TotalTrips,
        SUM(t.total_amount) AS TotalPassengerCharges,
        AVG(t.total_amount) AS AvgTripCharge

    FROM dbo.yellow_trips_raw AS t

    INNER JOIN dbo.taxi_zones AS z
        ON t.pu_location_id = z.location_id

    WHERE t.pickup_datetime >= '2025-01-01'
      AND t.pickup_datetime < '2025-02-01'
      AND t.dropoff_datetime > t.pickup_datetime
      AND t.trip_distance > 0
      AND t.total_amount > 0
      AND t.pu_location_id IS NOT NULL
      AND t.do_location_id IS NOT NULL

    GROUP BY z.borough
),
BoroughRanking AS (
    SELECT