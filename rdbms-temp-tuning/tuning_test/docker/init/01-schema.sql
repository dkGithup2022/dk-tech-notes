-- 01-schema.sql
-- 9개 테이블. 일부 인덱스는 의도적으로 누락 (Case F 에서 활용).
-- FK 는 MySQL 학습용 단순화를 위해 생략.

USE tuning;

SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS shipments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS warehouses;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS categories;

-- ========== categories (50) ==========
CREATE TABLE categories (
  id         INT PRIMARY KEY,
  parent_id  INT NULL,
  name       VARCHAR(80) NOT NULL,
  INDEX idx_parent (parent_id)
) ENGINE=InnoDB;

-- ========== suppliers (100) ==========
CREATE TABLE suppliers (
  id    INT PRIMARY KEY,
  name  VARCHAR(100) NOT NULL,
  region VARCHAR(40) NOT NULL,
  INDEX idx_region (region)
) ENGINE=InnoDB;

-- ========== warehouses (5) ==========
CREATE TABLE warehouses (
  id    INT PRIMARY KEY,
  name  VARCHAR(40) NOT NULL,
  city  VARCHAR(40) NOT NULL
) ENGINE=InnoDB;

-- ========== products (10,000) ==========
CREATE TABLE products (
  id           INT PRIMARY KEY,
  name         VARCHAR(120) NOT NULL,
  category_id  INT NOT NULL,
  supplier_id  INT NOT NULL,
  warehouse_id INT NOT NULL,
  price        DECIMAL(10,2) NOT NULL,
  created_at   DATE NOT NULL,
  INDEX idx_category (category_id),
  INDEX idx_supplier (supplier_id),
  INDEX idx_created_at (created_at)
) ENGINE=InnoDB;

-- ========== users (2,000) ==========
CREATE TABLE users (
  id     INT PRIMARY KEY,
  name   VARCHAR(60) NOT NULL,
  region VARCHAR(20) NOT NULL,
  INDEX idx_region (region)
) ENGINE=InnoDB;

-- ========== orders (5,000) ==========
CREATE TABLE orders (
  id         INT PRIMARY KEY,
  user_id    INT NOT NULL,
  order_date DATE NOT NULL,
  amount     DECIMAL(10,2) NOT NULL,
  INDEX idx_user (user_id),
  INDEX idx_date (order_date)
) ENGINE=InnoDB;

-- ========== order_items (15,000) ==========
CREATE TABLE order_items (
  id         INT PRIMARY KEY,
  order_id   INT NOT NULL,
  product_id INT NOT NULL,
  qty        INT NOT NULL,
  INDEX idx_order (order_id),
  INDEX idx_product (product_id)
) ENGINE=InnoDB;

-- ========== shipments (10,000) ==========
-- 주의: status 에 인덱스 없음 (Case F 에서 활용)
CREATE TABLE shipments (
  id            INT PRIMARY KEY,
  order_id      INT NOT NULL,
  status        VARCHAR(20) NOT NULL,  -- 'PENDING'|'SHIPPED'|'DELIVERED'|'RETURNED'|'LOST'
  shipped_at    DATE NULL,
  delivered_at  DATE NULL,
  INDEX idx_order (order_id)
  -- idx_status 는 Case F 에서 ALTER 로 추가
) ENGINE=InnoDB;

-- ========== reviews (20,000) ==========
CREATE TABLE reviews (
  id         INT PRIMARY KEY,
  product_id INT NOT NULL,
  user_id    INT NOT NULL,
  rating     TINYINT NOT NULL,  -- 1~5
  created_at DATE NOT NULL,
  INDEX idx_product (product_id),
  INDEX idx_user (user_id)
) ENGINE=InnoDB;

SET FOREIGN_KEY_CHECKS = 1;

SELECT 'schema ready' AS status;
