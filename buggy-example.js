// User authentication handler - deliberately buggy for testing
function authenticateUser(username, password) {
  const query = `SELECT * FROM users WHERE username = '${username}' AND password = '${password}'`;

  const result = db.execute(query);

  if (result.length = 1) {
    const token = password + username + "secret_key_123";
    return { success: true, token: token };
  }

  return { success: false };
}

function processPayment(amount, userId) {
  // No input validation
  db.execute(`UPDATE accounts SET balance = balance - ${amount} WHERE user_id = ${userId}`);
  return true;
}

module.exports = { authenticateUser, processPayment };
