import React, { useState } from 'react';
import { ethers } from 'ethers';
import './App.css';

const LENDING_POOL_ADDRESS = import.meta.env.VITE_LENDING_POOL_ADDRESS;
const USDC_ADDRESS = import.meta.env.VITE_USDC_ADDRESS;
const RPC_URL = import.meta.env.VITE_RPC_URL || 'http://127.0.0.1:8545';

const LENDING_POOL_ABI = [
  "function deposit(address asset, uint256 amount) external",
  "function withdraw(address asset, uint256 amount) external",
  "function borrow(address asset, uint256 amount) external",
  "function repay(address asset, uint256 amount) external",
  "function getHealthFactor(address user) external view returns (uint256)",
  "function getSupplyBalance(address asset, address user) external view returns (uint256)",
  "function getDebtBalance(address asset, address user) external view returns (uint256)"
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)"
];

const readProvider = new ethers.JsonRpcProvider(RPC_URL);

export default function MiniAaveApp() {
  const [signer, setSigner] = useState(null);
  const [account, setAccount] = useState("");
  const [healthFactor, setHealthFactor] = useState("0");
  const [suppliedUSDC, setSuppliedUSDC] = useState("0");
  const [borrowedUSDC, setBorrowedUSDC] = useState("0");
  const [amount, setAmount] = useState("");
  const [status, setStatus] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const connectWallet = async () => {
    if (!window.ethereum) {
      alert("Please install MetaMask!");
      return;
    }
    try {
      const browserProvider = new ethers.BrowserProvider(window.ethereum);
      const tempSigner = await browserProvider.getSigner();
      const address = await tempSigner.getAddress();
      setSigner(tempSigner);
      setAccount(address);

      const code = await readProvider.getCode(LENDING_POOL_ADDRESS);
      if (code === '0x') {
        setStatus("❌ Contract not found. Is Anvil running?");
        return;
      }
      await fetchUserData(address);
    } catch (error) {
      console.error("Wallet connection failed:", error);
      setStatus("❌ " + (error?.message || "Failed to connect wallet"));
    }
  };

  const fetchUserData = async (userAddress) => {
    if (!userAddress) return;
    try {
      const poolContract = new ethers.Contract(LENDING_POOL_ADDRESS, LENDING_POOL_ABI, readProvider);
      const [hf, supplied, borrowed] = await Promise.all([
        poolContract.getHealthFactor(userAddress),
        poolContract.getSupplyBalance(USDC_ADDRESS, userAddress),
        poolContract.getDebtBalance(USDC_ADDRESS, userAddress),
      ]);

      setSuppliedUSDC(ethers.formatUnits(supplied, 6));
      setBorrowedUSDC(ethers.formatUnits(borrowed, 6));

      const hfFloat = parseFloat(ethers.formatUnits(hf, 18));
      setHealthFactor(hfFloat > 1e6 ? "∞" : hfFloat.toFixed(4));
    } catch (error) {
      console.error("Error fetching user data:", error);
      setStatus("❌ Failed to fetch data. Check console.");
    }
  };

  const handleDeposit = async () => {
    if (!signer || !amount) return;
    setIsLoading(true);
    setStatus("");
    try {
      const parsedAmount = ethers.parseUnits(amount, 6);
      const usdcContract = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, signer);
      const poolContract = new ethers.Contract(LENDING_POOL_ADDRESS, LENDING_POOL_ABI, signer);
      const userAddress = await signer.getAddress();
      const currentAllowance = await usdcContract.allowance(userAddress, LENDING_POOL_ADDRESS);

      if (currentAllowance < parsedAmount) {
        setStatus("⏳ Approving USDC...");
        const approveTx = await usdcContract.approve(LENDING_POOL_ADDRESS, parsedAmount);
        await approveTx.wait();
      }

      setStatus("⏳ Depositing...");
      const depositTx = await poolContract.deposit(USDC_ADDRESS, parsedAmount);
      setStatus("⏳ Waiting for confirmation...");
      await depositTx.wait();

      setStatus("✅ Deposit successful!");
      setAmount("");
      await fetchUserData(userAddress);
    } catch (error) {
      console.error("Deposit failed", error);
      setStatus(`❌ Deposit failed: ${error?.reason || error?.message || "Unknown error"}`);
    } finally {
      setIsLoading(false);
    }
  };

  const handleBorrow = async () => {
    if (!signer || !amount) return;
    setIsLoading(true);
    setStatus("");
    try {
      const parsedAmount = ethers.parseUnits(amount, 6);
      const poolContract = new ethers.Contract(LENDING_POOL_ADDRESS, LENDING_POOL_ABI, signer);
      const userAddress = await signer.getAddress();

      setStatus("⏳ Borrowing...");
      const borrowTx = await poolContract.borrow(USDC_ADDRESS, parsedAmount);
      setStatus("⏳ Waiting for confirmation...");
      await borrowTx.wait();

      setStatus("✅ Borrow successful!");
      setAmount("");
      await fetchUserData(userAddress);
    } catch (error) {
      console.error("Borrow failed", error);
      setStatus(`❌ Borrow failed: ${error?.reason || error?.message || "Unknown error"}`);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="cyber-container">
      {/* Header */}
      <header className="cyber-header">
        <div className="logo-area">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--primary-cyan)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polygon points="12 2 2 22 22 22"></polygon>
          </svg>
          Web3
        </div>
        <div className="nav-links">
          <span>Lending</span>
          <span>Facility</span>
          <span>Protocol</span>
        </div>
        <div className="header-right">
          {account ? (
            <div className="wallet-address">
              {account.slice(0, 6)}...{account.slice(-4)}
            </div>
          ) : (
            <button className="connect-wallet-btn" onClick={connectWallet}>
              Connect Wallet
            </button>
          )}
        </div>
      </header>

      {/* Sidebar */}
      <aside className="cyber-sidebar">
        <div className="sidebar-item active">
          <span>✦</span> Dashboard
        </div>
        <div className="sidebar-item">
          <span>❖</span> Wallet
        </div>
        <div className="sidebar-item">
          <span>◈</span> Health
        </div>
        <div className="sidebar-item">
          <span>◎</span> Smart Contract
        </div>
        <div className="sidebar-item">
          <span>⎔</span> Tokens
        </div>
        <div className="sidebar-item">
          <span>⚙</span> Settings
        </div>
      </aside>

      {/* Main Content */}
      <main className="cyber-main">
        {status && (
          <div className="status-message" style={{ color: status.startsWith('❌') ? 'var(--primary-red)' : 'var(--primary-green)', borderColor: status.startsWith('❌') ? 'var(--primary-red)' : 'var(--primary-green)' }}>
            {status}
          </div>
        )}

        <div className="dashboard-grid">
          {/* Health Factor Card */}
          <div className="cyber-card">
            <div className="card-title">
              Health Factor <span style={{color: 'var(--primary-cyan)'}}>⚡</span>
            </div>
            <div className="card-value">
              {healthFactor}
            </div>
            <div className="card-sub">
              Liquidation threshold: &lt; 1.0
            </div>
            <div className="mock-chart">
              <div className="bar" style={{height: '40%'}}></div>
              <div className="bar" style={{height: '60%'}}></div>
              <div className="bar" style={{height: '30%'}}></div>
              <div className="bar" style={{height: '80%'}}></div>
              <div className="bar" style={{height: '50%'}}></div>
              <div className="bar" style={{height: '90%'}}></div>
              <div className="bar" style={{height: '70%'}}></div>
            </div>
          </div>

          {/* Supplied Card */}
          <div className="cyber-card">
            <div className="card-title">
              Total Supplied <span style={{color: 'var(--primary-green)'}}>↑</span>
            </div>
            <div className="card-value green-text">
              {suppliedUSDC} <span style={{fontSize: '16px', color: 'var(--text-muted)'}}>USDC</span>
            </div>
            <div className="card-sub">
              Earning APY
            </div>
            <div className="line-chart">
              <div className="line-path"></div>
            </div>
          </div>

          {/* Borrowed Card */}
          <div className="cyber-card">
            <div className="card-title">
              Total Borrowed <span style={{color: 'var(--primary-red)'}}>↓</span>
            </div>
            <div className="card-value" style={{color: 'var(--primary-red)', textShadow: '0 0 10px rgba(255,42,42,0.5)'}}>
              {borrowedUSDC} <span style={{fontSize: '16px', color: 'var(--text-muted)'}}>USDC</span>
            </div>
            <div className="card-sub">
              Paying APR
            </div>
            <div className="line-chart">
              <div className="line-path" style={{borderTopColor: 'var(--primary-red)', background: 'linear-gradient(to top, rgba(255,42,42,0.2), transparent)'}}></div>
            </div>
          </div>
        </div>

        {/* Action Area */}
        <div className="action-area">
          <div className="input-wrapper">
            <input
              type="number"
              className="cyber-input"
              placeholder="0.00 USDC"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              disabled={isLoading || !account}
            />
          </div>
          
          <div className="button-group">
            <button 
              className="cyber-button btn-supply" 
              onClick={handleDeposit}
              disabled={isLoading || !account || !amount}
            >
              {isLoading ? 'Processing' : 'Supply'}
            </button>
            <button 
              className="cyber-button btn-borrow" 
              onClick={handleBorrow}
              disabled={isLoading || !account || !amount}
            >
              {isLoading ? 'Processing' : 'Borrow'}
            </button>
          </div>
        </div>
      </main>
    </div>
  );
}