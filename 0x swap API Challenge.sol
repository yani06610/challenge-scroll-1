import { config as dotenv } from "dotenv";
import {
  createWalletClient,
  http,
  getContract,
  erc20Abi,
  parseUnits,
  maxUint256,
  publicActions,
  concat,
  numberToHex,
  size,
} from "viem";
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { scroll } from "viem/chains";
import { wethAbi } from "./abi/weth-abi";

const qs = require("qs");

// Charger les variables d'environnement
dotenv();
const { PRIVATE_KEY, ZERO_EX_API_KEY, ALCHEMY_HTTP_TRANSPORT_URL } = process.env;

// Validation des variables d'environnement nécessaires
if (!PRIVATE_KEY) throw new Error("Missing PRIVATE_KEY.");
if (!ZERO_EX_API_KEY) throw new Error("Missing ZERO_EX_API_KEY.");
if (!ALCHEMY_HTTP_TRANSPORT_URL) throw new Error("Missing ALCHEMY_HTTP_TRANSPORT_URL.");

// Créer les en-têtes d'API
const headers = new Headers({
  "Content-Type": "application/json",
  "0x-api-key": ZERO_EX_API_KEY,
  "0x-version": "v2",
});

// Configurer le client du portefeuille
const client = createWalletClient({
  account: privateKeyToAccount(`0x${PRIVATE_KEY}` as `0x${string}`),
  chain: scroll,
  transport: http(ALCHEMY_HTTP_TRANSPORT_URL),
}).extend(publicActions);

const [address] = await client.getAddresses();

// Définir les contrats
const weth = getContract({
  address: "0x5300000000000000000000000000000000000004",
  abi: wethAbi,
  client,
});

const wsteth = getContract({
  address: "0xf610A9dfB7C89644979b4A0f27063E9e7d7Cda32",
  abi: erc20Abi,
  client,
});

// Fonction pour afficher le pourcentage de répartition des sources de liquidité
function displayLiquiditySources(route: any) {
  const fills = route.fills;
  const totalBps = fills.reduce((acc: number, fill: any) => acc + parseInt(fill.proportionBps), 0);

  console.log(`${fills.length} Sources`);
  fills.forEach((fill: any) => {
    const percentage = (parseInt(fill.proportionBps) / 100).toFixed(2);
    console.log(`${fill.source}: ${percentage}%`);
  });
}

// Fonction pour afficher les taxes d'achat/vente pour les tokens
function displayTokenTaxes(tokenMetadata: any) {
  const buyTokenBuyTax = (parseInt(tokenMetadata.buyToken.buyTaxBps) / 100).toFixed(2);
  const buyTokenSellTax = (parseInt(tokenMetadata.buyToken.sellTaxBps) / 100).toFixed(2);
  const sellTokenBuyTax = (parseInt(tokenMetadata.sellToken.buyTaxBps) / 100).toFixed(2);
  const sellTokenSellTax = (parseInt(tokenMetadata.sellToken.sellTaxBps) / 100).toFixed(2);

  if (buyTokenBuyTax > 0 || buyTokenSellTax > 0) {
    console.log(`Buy Token Buy Tax: ${buyTokenBuyTax}%`);
    console.log(`Buy Token Sell Tax: ${buyTokenSellTax}%`);
  }

  if (sellTokenBuyTax > 0 || sellTokenSellTax > 0) {
    console.log(`Sell Token Buy Tax: ${sellTokenBuyTax}%`);
    console.log(`Sell Token Sell Tax: ${sellTokenSellTax}%`);
  }
}

// Fonction pour afficher toutes les sources de liquidité sur Scroll
const getLiquiditySources = async () => {
  const chainId = client.chain.id.toString(); // Assurez-vous que c'est l'ID correct pour Scroll
  const sourcesParams = new URLSearchParams({
    chainId: chainId,
  });

  const sourcesResponse = await fetch(
    `https://api.0x.org/swap/v1/sources?${sourcesParams.toString()}`,
    {
      headers,
    }
  );

  const sourcesData = await sourcesResponse.json();
  const sources = Object.keys(sourcesData.sources);
  console.log("Sources de liquidité pour Scroll chain:");
  console.log(sources.join(", "));
};

const main = async () => {
  // Afficher toutes les sources de liquidité sur Scroll
  await getLiquiditySources();

  // Définir le montant de vente
  const decimals = (await weth.read.decimals()) as number;
  const sellAmount = parseUnits("0.1", decimals);

  // Ajouter des paramètres pour les frais d'affiliation et la collecte de surplus
  const affiliateFeeBps = "100"; // 1%
  const surplusCollection = "true";

  // Obtenir le prix avec les paramètres de monétisation
  const priceParams = new URLSearchParams({
    chainId: client.chain.id.toString(),
    sellToken: weth.address,
    buyToken: wsteth.address,
    sellAmount: sellAmount.toString(),
    taker: client.account.address,
    affiliateFee: affiliateFeeBps, // Paramètre pour les frais d'affiliation
    surplusCollection: surplusCollection, // Paramètre pour la collecte de surplus
  });

  const priceResponse = await fetch(
    "https://api.0x.org/swap/permit2/price?" + priceParams.toString(),
    {
      headers,
    }
  );

  const price = await priceResponse.json();
  console.log("Fetching price to swap 0.1 WETH for wstETH");
  console.log(
    `https://api.0x.org/swap/permit2/price?${priceParams.toString()}`
  );
  console.log("priceResponse: ", price);

  // Vérifier si le preneur doit définir une allocation pour Permit2
  if (price.issues.allowance !== null) {
    try {
      const { request } = await weth.simulate.approve([
        price.issues.allowance.spender,
        maxUint256,
      ]);
      console.log("Approving Permit2 to spend WETH...", request);

      // Définir l'approbation
      const hash = await weth.write.approve(request.args);
      console.log(
        "Approved Permit2 to spend WETH.",
        await client.waitForTransactionReceipt({ hash })
      );
    } catch (error) {
      console.log("Error approving Permit2:", error);
    }
  } else {
    console.log("WETH already approved for Permit2");
  }

  // Obtenir le devis avec les paramètres de monétisation
  const quoteParams = new URLSearchParams(priceParams);

  const quoteResponse = await fetch(
    "https://api.0x.org/swap/permit2/quote?" + quoteParams.toString(),
    {
      headers,
    }
  );

  const quote = await quoteResponse.json();
  console.log("Fetching quote to swap 0.1 WETH for wstETH");
  console.log("quoteResponse: ", quote);

  // Afficher la répartition des sources de liquidité
  if (quote.route) {
    displayLiquiditySources(quote.route);
  }

  // Afficher les taxes d'achat/vente des tokens
  if (quote.tokenMetadata) {
    displayTokenTaxes(quote.tokenMetadata);
  }

  // Afficher les informations de monétisation
  if (quote.affiliateFeeBps) {
    const affiliateFee = (parseInt(quote.affiliateFeeBps) / 100).toFixed(2);
    console.log(`Affiliate Fee: ${affiliateFee}%`);
  }

  if (quote.tradeSurplus && parseFloat(quote.tradeSurplus) > 0) {
    console.log(`Trade Surplus Collected: ${quote.tradeSurplus}`);
  }

  // Signer le message permit2.eip712 retourné par le devis
  let signature: Hex | undefined;
  if (quote.permit2?.eip712) {
    try {
      signature = await client.signTypedData(quote.permit2.eip712);
      console.log("Signed permit2 message from quote response");
    } catch (error) {
      console.error("Error signing permit2 coupon:", error);
    }

    // Ajouter la signature à la transaction
    if (signature && quote?.transaction?.data) {
      const signatureLengthInHex = numberToHex(size(signature), {
        signed: false,
        size: 32,
      });

      const transactionData = quote.transaction.data as Hex;
      const sigLengthHex = signatureLengthInHex as Hex;
      const sig = signature as Hex;

      quote.transaction.data = concat([transactionData, sigLengthHex, sig]);
    } else {
      throw new Error("Failed to obtain signature or transaction data");
    }
  }

  // Soumettre la transaction avec la signature permit2
  if (signature && quote.transaction.data) {
    const nonce = await client.getTransactionCount({
      address: client.account.address,
    });

    const signedTransaction = await client.signTransaction({
      account: client.account,
      chain: client.chain,
      gas: quote?.transaction.gas
