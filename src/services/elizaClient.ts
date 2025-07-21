import axios, { AxiosInstance } from "axios";

export class ElizaClient {
  private api: AxiosInstance;

  constructor(private baseUrl: string) {
    this.api = axios.create({ baseURL: baseUrl });
  }

  /**
   * Execute a write action via ElizaOS
   * @param method Name of the protocol action, e.g. "supply", "borrow"
   * @param args   Arguments required by the action (symbol, amount, etc.)
   * @param from   The wallet address initiating the TX
   * @returns      Transaction hash string returned by ElizaOS
   */
  async executeWrite(
    method: string,
    args: Record<string, string | number>,
    from: string
  ): Promise<string> {
    const res = await this.api.post("/tx", {
      method,
      args,
      from,
    });
    if (!res.data?.txHash) {
      throw new Error("Invalid response from ElizaOS");
    }
    return res.data.txHash as string;
  }
}
