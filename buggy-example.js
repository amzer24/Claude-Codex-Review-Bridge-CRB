const crypto = require("crypto");

function authenticateUser(db, username, password) {
  const result = db.execute(
    "SELECT id, password_hash FROM users WHERE username = ?",
    [username]
  );

  if (result.length !== 1) {
    return { success: false };
  }

  const user = result[0];
  const hash = crypto.createHash("sha256").update(password).digest("hex");
  if (hash !== user.password_hash) {
    return { success: false };
  }

  const token = crypto.randomBytes(32).toString("hex");
  return { success: true, token };
}

function processPayment(db, amount, userId) {
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0) {
    throw new Error("Invalid payment amount");
  }
  if (typeof userId !== "string" || userId.length === 0) {
    throw new Error("Invalid user ID");
  }

  const result = db.execute(
    "UPDATE accounts SET balance = balance - ? WHERE user_id = ? AND balance >= ?",
    [amount, userId, amount]
  );

  if (result.affectedRows !== 1) {
    throw new Error("Payment failed: insufficient balance or user not found");
  }

  return true;
}

module.exports = { authenticateUser, processPayment };
