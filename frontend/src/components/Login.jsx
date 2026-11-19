import { useState } from 'react';
import { loginApp } from '../api/client';
import HealthIcon from './HealthIcon';

export default function Login({ onLoginSuccess }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await loginApp(username, password);
      onLoginSuccess();
    } catch (err) {
      setError('登录失败，请检查用户名和密码后重试');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="health-login">
      <div className="health-login-card">
        <span className="health-brand-mark"><HealthIcon size={28} /></span>
        <h1>Health</h1>
        <p>登录以查看你的健康与训练记录</p>

        <form onSubmit={handleSubmit}>
          <div>
            <label htmlFor="health-username">
              用户名
            </label>
            <input
              type="text"
              id="health-username"
              autoComplete="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="输入用户名"
              required
            />
          </div>

          <div>
            <label htmlFor="health-password">
              密码
            </label>
            <input
              type="password"
              id="health-password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="输入密码"
              required
            />
          </div>

          {error && <div className="health-login-error" role="alert">{error}</div>}

          <button
            type="submit"
            disabled={loading}
          >
            {loading ? '正在登录…' : '登录'}
          </button>
        </form>
      </div>
    </div>
  );
}
