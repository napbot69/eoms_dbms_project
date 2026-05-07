-- ============================================================
-- E-Commerce Order Management System (EOMS)
-- Database Setup Script
-- ============================================================

CREATE DATABASE IF NOT EXISTS ecommerce_oms;
USE ecommerce_oms;

-- 1. CATEGORY TABLE
CREATE TABLE IF NOT EXISTS CATEGORY (
    category_id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);

-- 2. SUPPLIER TABLE
CREATE TABLE IF NOT EXISTS SUPPLIER (
    supplier_id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    contact_email VARCHAR(100)
);

-- 3. CUSTOMER TABLE
CREATE TABLE IF NOT EXISTS CUSTOMER (
    customer_id INT AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    phone VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. ADDRESS TABLE
CREATE TABLE IF NOT EXISTS ADDRESS (
    address_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT,
    address_line1 VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    pincode VARCHAR(10),
    FOREIGN KEY (customer_id) REFERENCES CUSTOMER(customer_id) ON DELETE CASCADE
);

-- 5. DISCOUNT TABLE
CREATE TABLE IF NOT EXISTS DISCOUNT (
    discount_id INT AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(20) UNIQUE,
    discount_pct DECIMAL(5,2)
);

-- 6. PRODUCT TABLE
CREATE TABLE IF NOT EXISTS PRODUCT (
    product_id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(10,2) NOT NULL,
    stock_qty INT DEFAULT 0,
    category_id INT,
    supplier_id INT,
    FOREIGN KEY (category_id) REFERENCES CATEGORY(category_id),
    FOREIGN KEY (supplier_id) REFERENCES SUPPLIER(supplier_id)
);

-- 7. ORDERS TABLE
CREATE TABLE IF NOT EXISTS ORDERS (
    order_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT,
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status ENUM('PENDING', 'CONFIRMED', 'SHIPPED', 'DELIVERED', 'CANCELLED') DEFAULT 'PENDING',
    total_amount DECIMAL(10,2),
    discount_id INT,
    address_id INT,
    FOREIGN KEY (customer_id) REFERENCES CUSTOMER(customer_id),
    FOREIGN KEY (discount_id) REFERENCES DISCOUNT(discount_id),
    FOREIGN KEY (address_id) REFERENCES ADDRESS(address_id)
);

-- 8. ORDER_ITEM TABLE
CREATE TABLE IF NOT EXISTS ORDER_ITEM (
    order_id INT,
    product_id INT,
    quantity INT,
    price_at_purchase DECIMAL(10,2),
    PRIMARY KEY (order_id, product_id),
    FOREIGN KEY (order_id) REFERENCES ORDERS(order_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES PRODUCT(product_id)
);

-- 9. PAYMENT TABLE
CREATE TABLE IF NOT EXISTS PAYMENT (
    payment_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT,
    amount DECIMAL(10,2),
    status ENUM('SUCCESS', 'FAILED', 'PENDING') DEFAULT 'SUCCESS',
    method VARCHAR(50),
    payment_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (order_id) REFERENCES ORDERS(order_id)
);

-- 10. SHIPMENT TABLE
CREATE TABLE IF NOT EXISTS SHIPMENT (
    shipment_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id INT,
    status ENUM('PENDING', 'READY_FOR_PICKUP', 'IN_TRANSIT', 'DELIVERED') DEFAULT 'PENDING',
    carrier VARCHAR(100),
    tracking_no VARCHAR(100),
    shipped_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (order_id) REFERENCES ORDERS(order_id)
);

-- 11. REVIEW TABLE
CREATE TABLE IF NOT EXISTS REVIEW (
    review_id INT AUTO_INCREMENT PRIMARY KEY,
    product_id INT,
    customer_id INT,
    rating INT CHECK (rating BETWEEN 1 AND 5),
    comment TEXT,
    reviewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES PRODUCT(product_id),
    FOREIGN KEY (customer_id) REFERENCES CUSTOMER(customer_id)
);

-- 12. PRICE LOG (For Audit/Triggers)
CREATE TABLE IF NOT EXISTS PRICE_LOG (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    product_id INT,
    old_price DECIMAL(10,2),
    new_price DECIMAL(10,2),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ── TRIGGERS ───────────────────────────────────────────────

-- Trigger 1: Track Price Changes
DELIMITER //
CREATE TRIGGER trg_price_change
AFTER UPDATE ON PRODUCT
FOR EACH ROW
BEGIN
    IF OLD.price <> NEW.price THEN
        INSERT INTO PRICE_LOG(product_id, old_price, new_price)
        VALUES(OLD.product_id, OLD.price, NEW.price);
    END IF;
END //
DELIMITER ;

-- Trigger 2: Sync Shipment status with Order status
DELIMITER //
CREATE TRIGGER trg_sync_shipment
AFTER UPDATE ON ORDERS
FOR EACH ROW
BEGIN
    IF NEW.status = 'DELIVERED' THEN
        UPDATE SHIPMENT SET status = 'DELIVERED' WHERE order_id = NEW.order_id;
    ELSEIF NEW.status = 'SHIPPED' THEN
        UPDATE SHIPMENT SET status = 'IN_TRANSIT' WHERE order_id = NEW.order_id;
    ELSEIF NEW.status = 'CONFIRMED' THEN
        UPDATE SHIPMENT SET status = 'READY_FOR_PICKUP' WHERE order_id = NEW.order_id;
    END IF;
END //
DELIMITER ;

-- ── VIEWS ──────────────────────────────────────────────────

CREATE OR REPLACE VIEW vw_product_performance AS
SELECT 
    p.name AS product_name, 
    c.name AS category, 
    p.price, 
    SUM(oi.quantity) AS units_sold, 
    COALESCE(AVG(r.rating), 0) AS avg_rating
FROM PRODUCT p
LEFT JOIN CATEGORY c ON p.category_id = c.category_id
LEFT JOIN ORDER_ITEM oi ON p.product_id = oi.product_id
LEFT JOIN REVIEW r ON p.product_id = r.product_id
GROUP BY p.product_id, p.name, c.name, p.price;

CREATE OR REPLACE VIEW vw_monthly_revenue AS
SELECT DATE_FORMAT(order_date, '%Y-%m') AS month, SUM(total_amount) AS revenue
FROM ORDERS
WHERE status != 'CANCELLED'
GROUP BY month;

CREATE OR REPLACE VIEW vw_customer_order_summary AS
SELECT c.customer_id, CONCAT(c.first_name, ' ', c.last_name) AS name, COUNT(o.order_id) AS total_orders, SUM(o.total_amount) AS lifetime_value
FROM CUSTOMER c
LEFT JOIN ORDERS o ON c.customer_id = o.customer_id
GROUP BY c.customer_id;

CREATE OR REPLACE VIEW vw_pending_shipments AS
SELECT 
    o.order_id, 
    CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
    o.order_date, 
    o.total_amount,
    s.carrier, 
    s.tracking_no,
    s.status AS shipment_status
FROM ORDERS o
JOIN CUSTOMER c ON o.customer_id = c.customer_id
JOIN SHIPMENT s ON o.order_id = s.order_id
WHERE s.status = 'PENDING';

-- ── STORED PROCEDURE ────────────────────────────────────────

DELIMITER //
CREATE PROCEDURE sp_place_order(
    IN p_cust_id INT,
    IN p_addr_id INT,
    IN p_disc_id INT,
    IN p_prod_id INT,
    IN p_qty INT,
    IN p_method VARCHAR(50)
)
BEGIN
    DECLARE v_price DECIMAL(10,2);
    DECLARE v_stock INT;
    DECLARE v_disc_pct DECIMAL(5,2) DEFAULT 0;
    DECLARE v_total DECIMAL(10,2);
    DECLARE v_order_id INT;
    DECLARE v_pay_status VARCHAR(20);
    
    -- Error Handler
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    
    -- 1. Check Stock and Price
    SELECT price, stock_qty INTO v_price, v_stock FROM PRODUCT WHERE product_id = p_prod_id;
    
    IF v_stock < p_qty THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock for this product';
    END IF;

    -- 2. Calculate Discount
    IF p_disc_id IS NOT NULL THEN
        SELECT discount_pct INTO v_disc_pct FROM DISCOUNT WHERE discount_id = p_disc_id;
    END IF;
    
    SET v_total = (v_price * p_qty) * (1 - (v_disc_pct / 100));

    -- 3. Create Order
    INSERT INTO ORDERS(customer_id, address_id, discount_id, total_amount, status)
    VALUES(p_cust_id, p_addr_id, p_disc_id, v_total, 'PENDING');
    
    SET v_order_id = LAST_INSERT_ID();
    
    -- 4. Add Order Item
    INSERT INTO ORDER_ITEM(order_id, product_id, quantity, price_at_purchase)
    VALUES(v_order_id, p_prod_id, p_qty, v_price);
    
    -- 5. Update Inventory (Stock Management)
    UPDATE PRODUCT SET stock_qty = stock_qty - p_qty WHERE product_id = p_prod_id;
    
    -- 6. Create Payment
    SET v_pay_status = IF(p_method = 'COD', 'PENDING', 'SUCCESS');
    INSERT INTO PAYMENT(order_id, amount, method, status)
    VALUES(v_order_id, v_total, p_method, v_pay_status);
    
    -- 7. Create Shipment
    INSERT INTO SHIPMENT(order_id, status, carrier)
    VALUES(v_order_id, 'PENDING', 'Standard');
    
    COMMIT;
    
    SELECT v_order_id AS order_id, 'Order placed successfully' AS message;
END //

CREATE PROCEDURE sp_get_top_customer()
BEGIN
    SELECT 
        c.customer_id, 
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name, 
        c.email,
        COUNT(o.order_id) AS total_orders
    FROM CUSTOMER c
    JOIN ORDERS o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id
    ORDER BY total_orders DESC
    LIMIT 1;
END //

DELIMITER ;

-- ── SAMPLE DATA ─────────────────────────────────────────────

INSERT INTO CATEGORY (name) VALUES ('Electronics'), ('Clothing'), ('Home & Garden'), ('Books');
INSERT INTO SUPPLIER (name, contact_email) VALUES ('TechGlobal', 'sales@techglobal.com'), ('FashionHub', 'info@fashionhub.com');

INSERT INTO CUSTOMER (first_name, last_name, email, phone) 
VALUES ('John', 'Doe', 'john@example.com', '1234567890'),
       ('Jane', 'Smith', 'jane@example.com', '9876543210');

INSERT INTO ADDRESS (customer_id, address_line1, city, state, pincode)
VALUES (1, '123 Main St', 'Mumbai', 'Maharashtra', '400001');

INSERT INTO DISCOUNT (code, discount_pct) VALUES ('SAVE10', 10.00), ('SAVE20', 20.00);

INSERT INTO PRODUCT (name, description, price, stock_qty, category_id, supplier_id)
VALUES ('Laptop', 'High-performance laptop', 75000.00, 50, 1, 1),
       ('Smartphone', 'Latest 5G phone', 35000.00, 120, 1, 1),
       ('T-Shirt', 'Cotton crew neck', 999.00, 500, 2, 2);

INSERT INTO ORDERS (customer_id, status, total_amount, address_id)
VALUES (1, 'PENDING', 75000.00, 1),
       (2, 'SHIPPED', 35000.00, NULL);

INSERT INTO ORDER_ITEM (order_id, product_id, quantity, price_at_purchase)
VALUES (1, 1, 1, 75000.00),
       (2, 2, 1, 35000.00);

INSERT INTO PAYMENT (order_id, amount, method, status)
VALUES (1, 75000.00, 'Credit Card', 'SUCCESS'),
       (2, 35000.00, 'UPI', 'SUCCESS');

INSERT INTO SHIPMENT (order_id, status, carrier, tracking_no)
VALUES (2, 'IN_TRANSIT', 'BlueDart', 'BD12345678');

INSERT INTO REVIEW (product_id, customer_id, rating, comment)
VALUES (1, 1, 5, 'Excellent performance!'),
       (2, 2, 4, 'Good phone but battery could be better.');
