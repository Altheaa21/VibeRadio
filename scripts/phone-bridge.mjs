// Private LAN bridge for the paired iPhone test; the Mac's localhost service stays unchanged.
import {networkInterfaces} from 'node:os';
import {randomBytes} from 'node:crypto';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createBridge} from '../server/server.mjs';
const folder=new URL('../.local/',import.meta.url);
await mkdir(folder,{recursive:true,mode:0o700});
const tokenFile=new URL('phone-bridge-token',folder);
let token;
try {token=(await readFile(tokenFile,'utf8')).trim();} catch(error) {if(error.code!=='ENOENT')throw error;token=randomBytes(32).toString('hex');await writeFile(tokenFile,token,{mode:0o600,flag:'wx'});}
if(!/^[a-f0-9]{64}$/.test(token))throw Error('Invalid local bridge token');
const wifi=(networkInterfaces().en0||[]).find(x=>x.family==='IPv4'&&!x.internal);
if(!wifi)throw Error('Connect this Mac to Wi-Fi before starting the iPhone bridge');
createBridge(undefined,token).listen(3301,wifi.address,()=>console.log(`iPhone music bridge: http://${wifi.address}:3301 (authenticated)`));
