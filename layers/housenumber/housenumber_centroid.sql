DROP TRIGGER IF EXISTS trigger_flag ON osm_housenumber_point;
DROP TRIGGER IF EXISTS trigger_flag ON osm_housenumber_polygon;
DROP TRIGGER IF EXISTS trigger_store ON osm_housenumber_point;
DROP TRIGGER IF EXISTS trigger_store ON osm_housenumber_polygon;
DROP TRIGGER IF EXISTS trigger_refresh ON housenumber.updates;

CREATE SCHEMA IF NOT EXISTS housenumber;

CREATE TABLE IF NOT EXISTS housenumber.osm_ids
(
    osm_id bigint
);

-- etldoc: osm_housenumber_point -> osm_housenumber_point
-- etldoc: osm_housenumber_polygon -> osm_housenumber_point
CREATE OR REPLACE FUNCTION convert_housenumber_point(full_update boolean) RETURNS void AS
$$
    -- Delete housenumber duplicates
    DELETE FROM osm_housenumber_point pt
    USING osm_housenumber_polygon poly
    WHERE pt.geometry && poly.geometry
          AND pt.housenumber = poly.housenumber
          AND (full_update OR pt.osm_id IN (SELECT osm_id FROM housenumber.osm_ids));

    INSERT INTO osm_housenumber_point (osm_id, housenumber, geometry)
        (SELECT 
            osm_id,
            housenumber,
            CASE
                WHEN ST_NPoints(ST_ConvexHull(geometry)) = ST_NPoints(geometry)
                    THEN ST_Centroid(geometry)
                ELSE ST_PointOnSurface(geometry)
            END AS geometry
        FROM osm_housenumber_polygon
        WHERE ST_IsValid(geometry)
            AND (full_update OR osm_id IN (SELECT osm_id FROM housenumber.osm_ids)));
$$ LANGUAGE SQL;

SELECT convert_housenumber_point(true);

-- Handle updates

CREATE OR REPLACE FUNCTION housenumber.store() RETURNS trigger AS
$$
BEGIN
    IF (tg_op = 'DELETE') THEN
        INSERT INTO housenumber.osm_ids VALUES (OLD.osm_id);
    ELSE
        INSERT INTO housenumber.osm_ids VALUES (NEW.osm_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS housenumber.updates
(
    id serial PRIMARY KEY,
    t text,
    UNIQUE (t)
);
CREATE OR REPLACE FUNCTION housenumber.flag() RETURNS trigger AS
$$
BEGIN
    INSERT INTO housenumber.updates(t) VALUES ('y') ON CONFLICT(t) DO NOTHING;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION housenumber.refresh() RETURNS trigger AS
$$
DECLARE
    t TIMESTAMP WITH TIME ZONE := clock_timestamp();
BEGIN
    RAISE LOG 'Refresh housenumber';
    PERFORM convert_housenumber_point(false);
    -- noinspection SqlWithoutWhere
    DELETE FROM housenumber.osm_ids;
    -- noinspection SqlWithoutWhere
    DELETE FROM housenumber.updates;

    RAISE LOG 'Refresh housenumber done in %', age(clock_timestamp(), t);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_store
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_housenumber_point
    FOR EACH ROW
EXECUTE PROCEDURE housenumber.store();

CREATE TRIGGER trigger_store
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_housenumber_polygon
    FOR EACH ROW
EXECUTE PROCEDURE housenumber.store();

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_housenumber_polygon
    FOR EACH STATEMENT
EXECUTE PROCEDURE housenumber.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT
    ON housenumber.updates
    INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE PROCEDURE housenumber.refresh();
