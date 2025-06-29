import OpenAI from "openai";

export class AIService {
  private openai: OpenAI;

  constructor(apiKey: string) {
    this.openai = new OpenAI({
      apiKey: apiKey,
    });
  }

  async getAdvice(userQuery: string, context?: any): Promise<string> {
    const systemPrompt = `You are a DeFi assistant specializing in Peridot protocol (a Compound V2 fork). 
    You help users understand:
    - Lending and borrowing mechanics in Peridot
    - Interest rates and yield farming with pTokens
    - Risk management and liquidation prevention
    - Peridottroller (Comptroller) functionality
    - Market analysis and optimization strategies
    
    Key terminology:
    - pTokens (instead of cTokens) - Peridot's interest-bearing tokens
    - Peridottroller (instead of Comptroller) - Main protocol controller
    - Supply/Mint - Depositing assets to earn interest
    - Borrow - Taking loans against collateral
    - Collateral Factor - Maximum borrowing power from supplied assets
    
    Always provide accurate, helpful advice and warn about risks like liquidation. 
    Keep responses concise but informative. Use emojis appropriately.`;

    const userPrompt = context
      ? `User question: ${userQuery}\n\nContext: ${JSON.stringify(
          context,
          null,
          2
        )}`
      : `User question: ${userQuery}`;

    try {
      const response = await this.openai.chat.completions.create({
        model: "gpt-3.5-turbo",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        max_tokens: 500,
        temperature: 0.7,
      });

      return (
        response.choices[0]?.message?.content ||
        "I couldn't generate a response."
      );
    } catch (error) {
      throw new Error(`AI service error: ${error}`);
    }
  }

  async analyzePosition(positionData: any): Promise<string> {
    const prompt = `Analyze this Peridot DeFi position and provide insights:
    ${JSON.stringify(positionData, null, 2)}
    
    Focus on:
    1. Health of the position (collateral vs debt)
    2. Risk factors and liquidation risk
    3. Optimization suggestions (rebalancing, etc.)
    4. Potential concerns or warnings
    5. APY opportunities
    
    Be specific about Peridot protocol mechanics and use appropriate terminology (pTokens, Peridottroller, etc.).`;

    try {
      const response = await this.openai.chat.completions.create({
        model: "gpt-3.5-turbo",
        messages: [
          {
            role: "system",
            content:
              "You are a Peridot DeFi risk analyst. Provide clear, actionable insights with specific recommendations.",
          },
          { role: "user", content: prompt },
        ],
        max_tokens: 400,
        temperature: 0.5,
      });

      return response.choices[0]?.message?.content || "Analysis unavailable.";
    } catch (error) {
      throw new Error(`Analysis error: ${error}`);
    }
  }

  async parseTransactionIntent(userMessage: string): Promise<{
    action: string;
    token: string;
    amount: string;
    confidence: number;
    warnings: string[];
  } | null> {
    const prompt = `Parse this user message for Peridot DeFi transaction intent:
    "${userMessage}"
    
    Identify:
    1. Action: supply/deposit, withdraw/redeem, borrow, repay
    2. Token symbol (USDC, USDT, P, ETH, etc.)
    3. Amount (number or "all"/"max")
    4. Confidence level (0-1, how certain you are about the intent)
    5. Any warnings needed (array of strings)
    
    Common phrases:
    - "supply", "deposit", "lend" → supply
    - "withdraw", "redeem", "unstake" → withdraw  
    - "borrow", "loan", "take out" → borrow
    - "repay", "pay back", "return" → repay
    
    Respond ONLY in valid JSON format:
    {
      "action": "supply|withdraw|borrow|repay",
      "token": "SYMBOL",
      "amount": "number_or_all",
      "confidence": 0.8,
      "warnings": ["warning1", "warning2"]
    }`;

    try {
      const response = await this.openai.chat.completions.create({
        model: "gpt-3.5-turbo",
        messages: [
          {
            role: "system",
            content:
              "You are a transaction intent parser. Respond ONLY with valid JSON.",
          },
          { role: "user", content: prompt },
        ],
        max_tokens: 200,
        temperature: 0.3,
      });

      const content = response.choices[0]?.message?.content;
      if (!content) return null;

      return JSON.parse(content);
    } catch (error) {
      console.error("Failed to parse transaction intent:", error);
      return null;
    }
  }

  async generateMarketSummary(marketData: any[]): Promise<string> {
    const prompt = `Generate a concise market summary for Peridot protocol:
    ${JSON.stringify(marketData, null, 2)}
    
    Include:
    - Top markets by TVL
    - Best supply/borrow rates
    - Market health indicators
    - Notable trends or opportunities
    
    Keep it under 300 words and use appropriate emojis.`;

    try {
      const response = await this.openai.chat.completions.create({
        model: "gpt-3.5-turbo",
        messages: [
          {
            role: "system",
            content: "You are a DeFi market analyst for Peridot protocol.",
          },
          { role: "user", content: prompt },
        ],
        max_tokens: 300,
        temperature: 0.6,
      });

      return (
        response.choices[0]?.message?.content || "Market data unavailable."
      );
    } catch (error) {
      throw new Error(`Market summary error: ${error}`);
    }
  }
}
