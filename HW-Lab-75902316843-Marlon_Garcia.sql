-- =============================================
-- EXPERIMENTO 1 - POSTGRESQL
-- =============================================

DROP TABLE IF EXISTS practica_oltp; --borrar tabla si ya existe

CREATE TABLE practica_oltp ( --crear tabla
    id BIGSERIAL PRIMARY KEY,
    nombre TEXT,
    saldo NUMERIC(10,2),
    created_at TIMESTAMP DEFAULT now()
);

-- Insertar 10 millones de registros
INSERT INTO practica_oltp (nombre, saldo)
SELECT 
    'Cliente ' || g,
    random()*10000
FROM generate_series(1,10000000) g;

SELECT COUNT(*) FROM practica_oltp; --validar los insert


-- Consulta puntual por PK
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM practica_oltp WHERE id = 5000000;

-- =============================================
-- EXPERIMENTO 1 - MYSQL
-- =============================================

DROP TABLE IF EXISTS practica_oltp; --borrar tabla si ya existe

CREATE TABLE practica_oltp ( --crear tabla
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100),
    saldo DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;



set session cte_max_recursion_depth = 10000000; --aumentar la sesion para poder insertar los 10M de registros

INSERT INTO practica_oltp (nombre, saldo)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 10000000
)
SELECT 
    MD5(RAND()),                 -- nombre
    ROUND(RAND()*10000, 2)       -- saldo
FROM seq;


SELECT COUNT(*) FROM practica_oltp; --Validar los Insert


EXPLAIN analyze --Ejecución de Explain
SELECT * FROM practica_oltp WHERE id = 5000000;



--Porque InnoDB usa índice clusterizado, mientras que PostgreSQL usa heap + índice separado.
--Cuando no hay caché, PostgreSQL necesita dos accesos a disco, InnoDB normalmente solo uno.



-- =============================================
-- EXPERIMENTO 2 - MySQL
-- =============================================


CREATE TABLE pk_bigint ( --crear tabla
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    data VARCHAR(100)
) ENGINE=InnoDB;

-- Tabla con PK UUID texto
CREATE TABLE pk_uuid (
    id CHAR(36) PRIMARY KEY,
    data VARCHAR(100)
) ENGINE=InnoDB;

-- Insertar 5 millones
INSERT INTO pk_bigint (data)
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 5000000
)
SELECT 
    MD5(RAND())
FROM seq;

INSERT INTO pk_uuid (id, data) --Insertar 5 millones en la otra tabka
WITH RECURSIVE seq AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 5000000
)
SELECT 
    UUID(),
    MD5(RAND())
FROM seq;

-- Tamaño en disco
SELECT table_name,
       round((data_length + index_length)/1024/1024,2) AS size_mb
FROM information_schema.tables
WHERE table_schema = DATABASE();

-- Fragmentación
SHOW TABLE STATUS LIKE 'pk_bigint';
SHOW TABLE STATUS LIKE 'pk_uuid';

-- El UUID como clave primaria genera mayor fragmentación en InnoDB porque el motor utiliza un índice clusterizado donde la PK determina el orden físico de las filas. Al ser aleatorio, el UUID provoca inserciones dispersas y frecuentes page splits, afectando tanto al índice como al almacenamiento físico de la tabla. En PostgreSQL, la tabla se almacena como heap independiente del índice, por lo que el UUID solo impacta la estructura del índice y no el layout físico de la tabla, reduciendo el efecto global de fragmentación


-- =============================================
-- EXPERIMENTO 3 - PostgreSQL
-- =============================================

DROP TABLE IF EXISTS mvcc_test; --borrar tabla si existe

CREATE TABLE mvcc_test (  --crear tabla
    id BIGSERIAL PRIMARY KEY,
    saldo NUMERIC(10,2)
);

--insertar 10M de registros
INSERT INTO mvcc_test (saldo)
SELECT random()*1000
FROM generate_series(1,10000000);

ANALYZE mvcc_test;

-- 1 millón de updates
UPDATE mvcc_test
SET saldo = saldo + 10
WHERE id <= 1000000;

-- Ver tuplas muertas
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'mvcc_test';

-- Tamaño antes de vacuum
SELECT pg_size_pretty(pg_total_relation_size('mvcc_test'));

--Ejecuatar VACUUM
VACUUM mvcc_test;

-- Tamaño después
SELECT pg_size_pretty(pg_total_relation_size('mvcc_test'));

-- En InnoDB, las versiones anteriores de las filas generadas por UPDATEs no permanecen en la tabla principal, sino que se almacenan en el undo log como parte del mecanismo MVCC. Esto evita la acumulación de filas muertas en el tablespace principal, produciendo un crecimiento temporal en el undo tablespace pero no un incremento sostenido del tamaño físico de la tabla. En contraste, PostgreSQL materializa cada actualización como una nueva fila en el heap, dejando versiones anteriores como dead tuples hasta que VACUUM las recupere, lo que genera mayor crecimiento y fragmentación del tablespace bajo cargas intensivas de UPDAT

-- =============================================
-- EXPERIMENTO 4 - PostgreSQL
-- =============================================

DROP TABLE IF EXISTS ventas; --borrar tabla si existe

CREATE TABLE ventas ( --crear tabla
    id BIGSERIAL PRIMARY KEY,
    region TEXT,
    producto TEXT,
    cliente TEXT,
    cantidad INT,
    precio NUMERIC,
    total NUMERIC,
    c1 TEXT, c2 TEXT, c3 TEXT, c4 TEXT, c5 TEXT,
    c6 TEXT, c7 TEXT, c8 TEXT, c9 TEXT
);

--Insertar 10M de registros
INSERT INTO ventas (region, producto, cliente, cantidad, precio, total)
SELECT
    CASE WHEN random() < 0.25 THEN 'Norte'
         WHEN random() < 0.5 THEN 'Sur'
         WHEN random() < 0.75 THEN 'Este'
         ELSE 'Oeste' END,
    md5(random()::text),
    md5(random()::text),
    (random()*10)::int,
    random()*100,
    random()*1000
FROM generate_series(1,10000000);


-- Query A
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM ventas WHERE region = 'Norte';

-- Query B
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(total), COUNT(*)
FROM ventas WHERE region = 'Norte';

-- Al comparar Query A y Query B se observa que ambas consultas se ejecutan sobre un modelo row-store, donde las páginas contienen filas completas. Sin embargo, Query B representa un patrón analítico típico, ya que solo requiere una columna para realizar agregaciones. En este escenario, un motor columnar resolvería la consulta de forma más eficiente, al leer exclusivamente las columnas involucradas y aplicar agregación vectorizada, reduciendo significativamente el I/O y el volumen de datos procesados. Por tanto, mientras PostgreSQL puede optimizar parcialmente mediante Index Only Scan, un column store ofrecería una mejora estructural y sostenida para cargas analíticas como Query B.

-- =============================================
-- EXPERIMENTO 5 - PostgreSQL
-- =============================================

-- Crear el Indice 
CREATE INDEX idx_ventas_covering 
ON ventas(region) 
INCLUDE (total);

--Ejecutar de nuevo

-- Query B
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(total), COUNT(*)
FROM ventas WHERE region = 'Norte';

--Comparar resultados.

--El uso del covering index permitió que PostgreSQL ejecutara la consulta mediante un Parallel Index Only Scan, eliminando prácticamente el acceso al heap (solo 12 heap fetches). Esto reduce significativamente el I/O y aproxima el comportamiento al de un motor columnar para esta consulta específica. Sin embargo, esta optimización depende del diseño explícito del índice y no modifica la arquitectura row-store subyacente del sistema. Por tanto, el covering index simula parcialmente el comportamiento columnar, pero no sustituye las ventajas estructurales de un motor columnar nativo en cargas analíticas generales.


