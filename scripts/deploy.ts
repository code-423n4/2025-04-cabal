import { AccAddress, MnemonicKey, MsgPublish, RESTClient, Wallet, bcs, MsgExecute, MsgDelegate, MsgSend } from '@initia/initia.js';
import { MoveBuilder } from '@initia/builder.js';
import * as fs from 'fs';
import JSONBig from 'json-bigint';

const mnemonic = 'yours here';
const path = 'yours here';
const args = process.argv.slice(2);  
const moduleName = args[0] || 'cabal' 
const file = moduleName + '.mv';

const restClient = new RESTClient('https://rest.testnet.initia.xyz', {
  chainId: 'initiation-2',
  gasPrices: '0.15uinit', // default gas prices
  gasAdjustment: '1.75',  // default gas adjustment for fee estimation
});

const key = new MnemonicKey({
  mnemonic
});
const wallet = new Wallet(restClient, key);

async function buildModule() {
  const builder = new MoveBuilder(path, {});
  await builder.build();
}

async function publishPackage() {
  const files = ['bribe', 'cabal_token', 'cabal', 'emergency', 'manager', 'package', 'pool_router', 'snapshots', 'utils', 'voting_reward'];
  const packageBytes = files.map(item => {
    const codeBytes = fs.readFileSync(
      `${path}/build/cabal/bytecode_modules/${item}.mv`
    );
    return codeBytes;
  })

  const msgs = [
    new MsgPublish(key.accAddress, packageBytes.map(item => item.toString('base64')), 1),
  ];

  // sign tx
  const signedTx = await wallet.createAndSignTx({ msgs });
  // send(broadcast) tx
  restClient.tx.broadcastSync(signedTx).then(res => console.log(res));
}

async function publishModule() {
  const codeBytes = fs.readFileSync(
    `${path}/build/cabal/bytecode_modules/${file}`
  );

  const msgs = [
    new MsgPublish(key.accAddress, [codeBytes.toString('base64')], 1),
  ];

  // sign tx
  const signedTx = await wallet.createAndSignTx({ msgs });
  // send(broadcast) tx
  restClient.tx.broadcastSync(signedTx).then(res => console.log(res));
}

async function init_manager() {
  const initManagerMsg = new MsgExecute(wallet.key.accAddress, wallet.key.accAddress, 'manager', 'initialize', undefined, [bcs.address().serialize(wallet.key.accAddress).toBase64()]);

  const msgs = [
    initManagerMsg,
  ];

  // sign tx
  const signedTx = await wallet.createAndSignTx({ msgs });

  // send(broadcast) tx
  restClient.tx.broadcastSync(signedTx).then(res => console.log(res));
}

async function init() {
  const initializeMsg = new MsgExecute(
    wallet.key.accAddress, 
    wallet.key.accAddress, moduleName, 'initialize', undefined, 
    [
      bcs.string().serialize('initvaloper14xmkxjzn6up5xzpc0nc4yfhjtr0a46exqkc2ee').toBase64(), 
      bcs.address().serialize(wallet.key.accAddress).toBase64()
    ]);

  const msgs = [
    initializeMsg,
  ];

  // sign tx
  const signedTx = await wallet.createAndSignTx({ msgs });

  // send(broadcast) tx
  restClient.tx.broadcastSync(signedTx).then(res => console.log(res));
}

async function config() {

  const m_store = await restClient.move.resource(wallet.key.accAddress, AccAddress.toHex(wallet.key.accAddress) + '::' + moduleName + '::ModuleStore');

  let data = JSONBig.parse(JSONBig.stringify(m_store.data));


  const usdcInitLpMsg = new MsgExecute(wallet.key.accAddress, wallet.key.accAddress, moduleName, 'config_stake_token', undefined, [
    bcs.u64().serialize(100).toBase64(),
    bcs.address().serialize('yours here').toBase64(),
    bcs.address().serialize('here').toBase64(),
    bcs.string().serialize("cabal stake uusdc-uinit LP coin").toBase64(),
    bcs.string().serialize("cabalINITUSDC").toBase64(),
    bcs.string().serialize("").toBase64(),
    bcs.string().serialize("").toBase64()
  ]);

  const addPoolMsg = new MsgExecute(wallet.key.accAddress, wallet.key.accAddress, 'pool_router', 'add_pool', undefined, [
    bcs.address().serialize('here').toBase64(),
    bcs.string().serialize("here").toBase64(),
  ]);


  const msgs = [
    usdcInitLpMsg,
    addPoolMsg
  ];

  // sign tx
  const signedTx = await wallet.createAndSignTx({ msgs });

  // send(broadcast) tx
  restClient.tx.broadcastSync(signedTx).then(res => console.log(res));
}

async function main() {
  // await buildModule()
  // await publishModule();

  await publishPackage();
  // await init_manager();
  // await init();
  // await config();
}

main()