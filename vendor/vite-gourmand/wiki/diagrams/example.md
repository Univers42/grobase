## Database Implementation Notes

### 🔧 Triggers to Implement

```sql
-- Auto-track order status changes (PostgreSQL syntax)
CREATE OR REPLACE FUNCTION fn_track_order_status()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO order_status_history (order_id, old_status, new_status, changed_by, changed_at)
        VALUES (NEW.id, OLD.status, NEW.status, NEW.assigned_to, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_status_change
AFTER UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION fn_track_order_status();

-- Auto-earn loyalty points on delivery
CREATE OR REPLACE FUNCTION fn_loyalty_earn()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'delivered' AND OLD.status != 'delivered' THEN
        -- Ensure loyalty account exists
        INSERT INTO loyalty_accounts (user_id, total_earned, total_spent, balance, last_activity_at)
        VALUES (NEW.user_id, 0, 0, 0, now())
        ON CONFLICT (user_id) DO NOTHING;

        -- Add points (10 per EUR)
        INSERT INTO loyalty_transactions (loyalty_account_id, order_id, points, type, description, created_at)
        VALUES (
            (SELECT id FROM loyalty_accounts WHERE user_id = NEW.user_id),
            NEW.id,
            FLOOR(NEW.total_amount * 10),
            'earn',
            'Order ' || NEW.order_number || ' delivered',
            now()
        );

        -- Update balance
        UPDATE loyalty_accounts
        SET total_earned = total_earned + FLOOR(NEW.total_amount * 10),
            balance = balance + FLOOR(NEW.total_amount * 10),
            last_activity_at = now()
        WHERE user_id = NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loyalty_earn
AFTER UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION fn_loyalty_earn();

-- Decrement menu stock on order confirmation
CREATE OR REPLACE FUNCTION fn_stock_decrement()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'confirmed' AND OLD.status = 'pending' THEN
        UPDATE menus SET remaining_qty = remaining_qty - 1
        WHERE id IN (SELECT menu_id FROM order_items WHERE order_id = NEW.id)
          AND remaining_qty > 0;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_decrement
AFTER UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION fn_stock_decrement();
```

### 📊 Views to Create

```sql
-- Active published menus with average ratings
CREATE VIEW v_active_menus AS
SELECT m.*, d.name AS diet_name, t.name AS theme_name,
       COALESCE(AVG(r.rating), 0) AS avg_rating,
       COUNT(r.id) AS review_count
FROM menus m
LEFT JOIN diets d ON m.diet_id = d.id
LEFT JOIN themes t ON m.theme_id = t.id
LEFT JOIN reviews r ON m.id = r.menu_id AND r.is_approved = true
WHERE m.status = 'published'
GROUP BY m.id, d.name, t.name;

-- Employee workload dashboard
CREATE VIEW v_employee_workload AS
SELECT u.id, u.first_name, u.last_name,
       COUNT(o.id) FILTER (WHERE o.status IN ('confirmed','preparing','delivering')) AS active_orders,
       COUNT(o.id) FILTER (WHERE o.status = 'delivered' AND o.delivered_at >= CURRENT_DATE) AS completed_today
FROM users u
LEFT JOIN orders o ON u.id = o.assigned_to
WHERE u.role_id = (SELECT id FROM roles WHERE name = 'employee')
  AND u.is_active = true
GROUP BY u.id;

-- Client loyalty overview
CREATE VIEW v_client_loyalty AS
SELECT u.id, u.first_name, u.email,
       COALESCE(la.balance, 0) AS loyalty_points,
       COUNT(o.id) AS total_orders,
       COALESCE(SUM(o.total_amount), 0) AS total_spent
FROM users u
LEFT JOIN loyalty_accounts la ON u.id = la.user_id
LEFT JOIN orders o ON u.id = o.user_id AND o.status = 'delivered'
WHERE u.role_id = (SELECT id FROM roles WHERE name = 'client')
  AND u.is_deleted = false
GROUP BY u.id, la.balance;
```

### 🔍 Essential Indexes

```sql
-- User authentication (hot path)
CREATE UNIQUE INDEX idx_users_email_active ON users(email) WHERE is_deleted = false;
CREATE INDEX idx_users_role ON users(role_id);

-- Order queries (most frequent)
CREATE UNIQUE INDEX idx_orders_number ON orders(order_number);
CREATE INDEX idx_orders_user_date ON orders(user_id, order_date DESC);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_assigned ON orders(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX idx_orders_delivery ON orders(delivery_date);

-- Menu search & filtering
CREATE INDEX idx_menus_status ON menus(status);
CREATE INDEX idx_menus_diet_theme ON menus(diet_id, theme_id);

-- Review moderation queue
CREATE INDEX idx_reviews_pending ON reviews(is_approved, created_at DESC);
CREATE INDEX idx_reviews_menu_approved ON reviews(menu_id) WHERE is_approved = true;

-- Notifications (unread badge)
CREATE INDEX idx_notifications_unread ON notifications(user_id, is_read) WHERE is_read = false;

-- Support tickets
CREATE INDEX idx_tickets_status_priority ON support_tickets(status, priority);
```
