import { v4 as uuidv4 } from "uuid";

interface UserSession {
  sessionId: string;
  userId: number;
  walletAddress?: string;
  createdAt: Date;
  lastInteraction: Date;
  onboardingStage?:
    | "asked_finance"
    | "asked_crypto"
    | "asked_strategy"
    | "wallet_choice"
    | "done";
  financeKnowledge?: "none" | "bit" | "lot";
  cryptoExperience?: "none" | "bit" | "lot";
  cryptoStrategy?: string;
  lastActivity: Date;
  preferences: {
    defaultMarket?: string;
    riskTolerance?: "low" | "medium" | "high";
    notificationsEnabled?: boolean;
    preferredChain?: string;
  };
  activeAlerts: string[];
}

const SESSION_TIMEOUT_MS = 24 * 60 * 60 * 1000; // 24 hours

export class UserSessionService {
  private sessions: Map<number, UserSession> = new Map();

  getSession(userId: number): UserSession {
    if (!this.sessions.has(userId)) {
      const session: UserSession = {
        sessionId: uuidv4(),
        userId,
        createdAt: new Date(),
        lastInteraction: new Date(),
        onboardingStage: "asked_finance",
        lastActivity: new Date(),
        preferences: {
          riskTolerance: "medium",
          notificationsEnabled: true,
          preferredChain: "arbitrum-sepolia",
        },
        activeAlerts: [],
      };
      this.sessions.set(userId, session);
    }

    const session = this.sessions.get(userId)!;
    session.lastInteraction = new Date();
    session.lastActivity = new Date();
    return session;
  }

  updateSession(userId: number, updates: Partial<UserSession>): void {
    const session = this.getSession(userId);
    Object.assign(session, updates, { lastInteraction: new Date() });
    this.sessions.set(userId, session);
  }

  setWallet(userId: number, address: string): void {
    const session = this.getSession(userId);
    session.walletAddress = address;
    this.sessions.set(userId, session);
  }

  getWallet(userId: number): string | undefined {
    return this.getSession(userId).walletAddress;
  }

  setPreference(
    userId: number,
    key: keyof UserSession["preferences"],
    value: any
  ): void {
    const session = this.getSession(userId);
    session.preferences[key] = value;
    this.sessions.set(userId, session);
  }

  getPreference(userId: number, key: keyof UserSession["preferences"]): any {
    return this.getSession(userId).preferences[key];
  }

  addAlert(userId: number, alertId: string): void {
    const session = this.getSession(userId);
    if (!session.activeAlerts.includes(alertId)) {
      session.activeAlerts.push(alertId);
      this.sessions.set(userId, session);
    }
  }

  removeAlert(userId: number, alertId: string): void {
    const session = this.getSession(userId);
    session.activeAlerts = session.activeAlerts.filter((id) => id !== alertId);
    this.sessions.set(userId, session);
  }

  getActiveAlerts(userId: number): string[] {
    return this.getSession(userId).activeAlerts;
  }

  getOnboardingStage(userId: number): UserSession["onboardingStage"] {
    return this.getSession(userId).onboardingStage;
  }

  setOnboardingStage(userId: number, stage: UserSession["onboardingStage"]) {
    const session = this.getSession(userId);
    session.onboardingStage = stage;
    this.sessions.set(userId, session);
  }

  setUserKnowledge(
    userId: number,
    knowledge: {
      financeKnowledge?: UserSession["financeKnowledge"];
      cryptoExperience?: UserSession["cryptoExperience"];
      cryptoStrategy?: UserSession["cryptoStrategy"];
    }
  ) {
    const session = this.getSession(userId);
    Object.assign(session, knowledge);
    this.sessions.set(userId, session);
  }

  // Clean up old inactive sessions (older than 30 days)
  cleanupOldSessions(): void {
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

    for (const [userId, session] of this.sessions.entries()) {
      if (session.lastInteraction < thirtyDaysAgo) {
        this.sessions.delete(userId);
      }
    }
  }

  // Get session statistics
  getStats(): {
    totalUsers: number;
    activeUsers: number;
    usersWithWallets: number;
  } {
    const total = this.sessions.size;
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);

    let activeUsers = 0;
    let usersWithWallets = 0;

    for (const session of this.sessions.values()) {
      if (session.lastInteraction > sevenDaysAgo) {
        activeUsers++;
      }
      if (session.walletAddress) {
        usersWithWallets++;
      }
    }

    return {
      totalUsers: total,
      activeUsers,
      usersWithWallets,
    };
  }
}
