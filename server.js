// ============================================================
// E-Commerce Order Management System — Backend Server
// Tech: Node.js + Express + mysql2
// Run: node server.js
// ============================================================

const express = require('express');
const mysql   = require('mysql2/promise');
const cors    = require('cors');
const path    = require('path');

const app  = express();
const PORT = 3002;

app.use(cors());
app.use(express.json());

// Serve frontend — works whether you run from inside or outside /eoms
const publicDir = path.join(__dirname, 'public');
app.use(express.static(publicDir));

// Explicit root → index.html (fixes "Cannot GET /index.html" on some setups)
app.get('/', (req, res) => res.sendFile(path.join(publicDir, 'index.html')));
app.get('/index.html', (req, res) => res.sendFile(path.join(publicDir, 'index.html')));

// ── DB Connection Pool ──────────────────────────────────────
const pool = mysql.createPool({
    host:               'localhost',
    user:               'root',          // ← change to your MySQL username
    password:           'aimbot',              // ← trying your password again
    database:           'ecommerce_oms',
    waitForConnections: true,
    connectionLimit:    10,
});

// ── Connection Test ─────────────────────────────────────────
pool.getConnection()
    .then(conn => {
        console.log('✅ Connected to MySQL successfully!');
        conn.release();
    })
    .catch(err => {
        console.error('❌ MySQL Connection Failed:');
        console.error('   Error Code:', err.code);
        console.error('   Message:', err.message);
        console.log('\n💡 Tip: Make sure MySQL is running and the password "aimbot" is correct for the user "root".');
    });

// ── Helper ──────────────────────────────────────────────────
async function query(sql, params = []) {
    const [rows] = await pool.execute(sql, params);
    return rows;
}

// ══════════════════════════════════════════════════════════════
// DASHBOARD STATS
// ══════════════════════════════════════════════════════════════
app.get('/api/stats', async (req, res) => {
    try {
        const [customers]  = await pool.execute('SELECT COUNT(*) AS total FROM CUSTOMER');
        const [products]   = await pool.execute('SELECT COUNT(*) AS total FROM PRODUCT');
        const [orders]     = await pool.execute('SELECT COUNT(*) AS total FROM ORDERS');
        const [revenue]    = await pool.execute("SELECT COALESCE(SUM(amount),0) AS total FROM PAYMENT WHERE status='SUCCESS'");
        const [pending]    = await pool.execute("SELECT COUNT(*) AS total FROM ORDERS WHERE status='PENDING'");
        const [lowstock]   = await pool.execute('SELECT COUNT(*) AS total FROM PRODUCT WHERE stock_qty < 100');
        const [topproduct] = await pool.execute(`
            SELECT p.name, SUM(oi.quantity) AS units
            FROM ORDER_ITEM oi JOIN PRODUCT p ON oi.product_id=p.product_id
            GROUP BY p.product_id ORDER BY units DESC LIMIT 1`);
        const [recentOrders] = await pool.execute(`
            SELECT o.order_id, CONCAT(c.first_name,' ',c.last_name) AS customer,
                   o.total_amount, o.status, o.order_date
            FROM ORDERS o JOIN CUSTOMER c ON o.customer_id=c.customer_id
            ORDER BY o.order_date DESC LIMIT 6`);

        res.json({
            customers:    customers[0].total,
            products:     products[0].total,
            orders:       orders[0].total,
            revenue:      revenue[0].total,
            pendingOrders:pending[0].total,
            lowStock:     lowstock[0].total,
            topProduct:   topproduct[0] || null,
            recentOrders,
        });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// CUSTOMERS
// ══════════════════════════════════════════════════════════════
app.get('/api/customers', async (req, res) => {
    try {
        const rows = await query(`
            SELECT c.customer_id, c.first_name, c.last_name, c.email, c.phone, c.created_at,
                   COUNT(o.order_id) AS total_orders,
                   COALESCE(SUM(o.total_amount),0) AS lifetime_value
            FROM CUSTOMER c
            LEFT JOIN ORDERS o ON c.customer_id=o.customer_id
            GROUP BY c.customer_id ORDER BY c.created_at DESC`);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/customers', async (req, res) => {
    const { first_name, last_name, email, phone } = req.body;
    try {
        const result = await query(
            'INSERT INTO CUSTOMER(first_name,last_name,email,phone) VALUES(?,?,?,?)',
            [first_name, last_name, email, phone]
        );
        res.json({ success: true, customer_id: result.insertId });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// PRODUCTS
// ══════════════════════════════════════════════════════════════
app.get('/api/products', async (req, res) => {
    try {
        const rows = await query(`
            SELECT p.*, cat.name AS category_name, s.name AS supplier_name,
                   COALESCE(AVG(r.rating),0) AS avg_rating,
                   COALESCE(COUNT(DISTINCT r.review_id),0) AS review_count
            FROM PRODUCT p
            LEFT JOIN CATEGORY cat ON p.category_id=cat.category_id
            LEFT JOIN SUPPLIER  s  ON p.supplier_id=s.supplier_id
            LEFT JOIN REVIEW    r  ON p.product_id=r.product_id
            GROUP BY p.product_id ORDER BY p.product_id`);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/products', async (req, res) => {
    const { name, description, price, stock_qty, category_id, supplier_id } = req.body;
    try {
        const result = await query(
            'INSERT INTO PRODUCT(name,description,price,stock_qty,category_id,supplier_id) VALUES(?,?,?,?,?,?)',
            [name, description, price, stock_qty, category_id, supplier_id]
        );
        res.json({ success: true, product_id: result.insertId });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// ORDERS
// ══════════════════════════════════════════════════════════════
app.get('/api/orders', async (req, res) => {
    try {
        const rows = await query(`
            SELECT o.order_id, CONCAT(c.first_name,' ',c.last_name) AS customer_name,
                   c.email, o.order_date, o.status, o.total_amount,
                   pay.method AS payment_method, pay.status AS payment_status,
                   sh.status AS shipment_status, sh.carrier, sh.tracking_no,
                   d.code AS discount_code, d.discount_pct
            FROM ORDERS o
            JOIN CUSTOMER c      ON o.customer_id = c.customer_id
            LEFT JOIN PAYMENT pay ON o.order_id   = pay.order_id
            LEFT JOIN SHIPMENT sh ON o.order_id   = sh.order_id
            LEFT JOIN DISCOUNT d  ON o.discount_id = d.discount_id
            ORDER BY o.order_date DESC`);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/orders/:id/items', async (req, res) => {
    try {
        const rows = await query(`
            SELECT oi.*, p.name AS product_name, p.description
            FROM ORDER_ITEM oi JOIN PRODUCT p ON oi.product_id=p.product_id
            WHERE oi.order_id=?`, [req.params.id]);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.patch('/api/orders/:id/status', async (req, res) => {
    const { status } = req.body;
    try {
        await query('UPDATE ORDERS SET status=? WHERE order_id=?', [status, req.params.id]);
        res.json({ success: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// Place order via stored procedure
app.post('/api/orders/place', async (req, res) => {
    const { customer_id, address_id, discount_id, product_id, quantity, method } = req.body;
    try {
        const rows = await query(
            'CALL sp_place_order(?,?,?,?,?,?)',
            [customer_id, address_id || 1, discount_id || null, product_id, quantity, method]
        );
        // CALL returns [[resultRows], okPacket] — grab first row
        const result = Array.isArray(rows[0]) ? rows[0][0] : rows[0];
        res.json(result);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// ANALYTICS / VIEWS
// ══════════════════════════════════════════════════════════════
app.get('/api/analytics/product-performance', async (req, res) => {
    try {
        const rows = await query('SELECT * FROM vw_product_performance ORDER BY units_sold DESC');
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/analytics/monthly-revenue', async (req, res) => {
    try {
        const rows = await query('SELECT * FROM vw_monthly_revenue');
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/analytics/customer-summary', async (req, res) => {
    try {
        const rows = await query('SELECT * FROM vw_customer_order_summary ORDER BY lifetime_value DESC');
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/analytics/pending-shipments', async (req, res) => {
    try {
        const rows = await query('SELECT * FROM vw_pending_shipments');
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// CATEGORIES & DISCOUNTS (for dropdowns)
// ══════════════════════════════════════════════════════════════
app.get('/api/categories', async (req, res) => {
    try { res.json(await query('SELECT * FROM CATEGORY ORDER BY name')); }
    catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/discounts', async (req, res) => {
    try { res.json(await query('SELECT * FROM DISCOUNT ORDER BY discount_pct DESC')); }
    catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/customers/:id/addresses', async (req, res) => {
    try {
        const rows = await query('SELECT * FROM ADDRESS WHERE customer_id=?', [req.params.id]);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ══════════════════════════════════════════════════════════════
// REVIEWS
// ══════════════════════════════════════════════════════════════
app.get('/api/reviews', async (req, res) => {
    try {
        const rows = await query(`
            SELECT r.*, CONCAT(c.first_name,' ',c.last_name) AS customer_name,
                   p.name AS product_name
            FROM REVIEW r
            JOIN CUSTOMER c ON r.customer_id=c.customer_id
            JOIN PRODUCT  p ON r.product_id=p.product_id
            ORDER BY r.reviewed_at DESC`);
        res.json(rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Start server ────────────────────────────────────────────
app.listen(PORT, () => {
    console.log(`\n🚀 EOMS Backend running at http://localhost:${PORT}`);
    console.log(`📊 Dashboard: http://localhost:${PORT}/index.html\n`);
});