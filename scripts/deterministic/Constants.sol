// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

/// @dev The default deterministic deployment salt prefix.
string constant DEFAULT_DEPLOYMENT_SALT = "ScrollStack";

/// @dev The address of DeterministicDeploymentProxy.
///      See https://github.com/Arachnid/deterministic-deployment-proxy.
address constant DETERMINISTIC_DEPLOYMENT_PROXY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @dev The default minimum withdraw amount configured on L2TxFeeVault.
uint256 constant FEE_VAULT_MIN_WITHDRAW_AMOUNT = 1 ether;

// template files
string constant CONFIG_CONTRACTS_TEMPLATE_PATH = "./docker/templates/config-contracts.toml";
string constant GENESIS_JSON_TEMPLATE_PATH = "./docker/templates/genesis.json";
string constant ROLLUP_CONFIG_TEMPLATE_PATH = "./docker/templates/rollup-config.json";
string constant COORDINATOR_CONFIG_TEMPLATE_PATH = "./docker/templates/coordinator-config.json";
string constant CHAIN_MONITOR_CONFIG_TEMPLATE_PATH = "./docker/templates/chain-monitor-config.json";
string constant BRIDGE_HISTORY_CONFIG_TEMPLATE_PATH = "./docker/templates/bridge-history-config.json";
string constant BALANCE_CHECKER_CONFIG_TEMPLATE_PATH = "./docker/templates/balance-checker-config.json";
string constant ROLLUP_EXPLORER_BACKEND_CONFIG_TEMPLATE_PATH = "./docker/templates/rollup-explorer-backend-config.json";
string constant ADMIN_SYSTEM_BACKEND_CONFIG_TEMPLATE_PATH = "./docker/templates/admin-system-backend-config.json";

// input files
string constant CONFIG_PATH = "./volume/config.toml";

// output files
string constant CONFIG_CONTRACTS_PATH = "./volume/config-contracts.toml";
string constant GENESIS_ALLOC_JSON_PATH = "./volume/__genesis-alloc.json";
string constant GENESIS_JSON_PATH = "./volume/genesis.yaml";
string constant ROLLUP_CONFIG_PATH = "./volume/rollup-config.yaml";
string constant COORDINATOR_CONFIG_PATH = "./volume/coordinator-config.yaml";
string constant CHAIN_MONITOR_CONFIG_PATH = "./volume/chain-monitor-config.yaml";
string constant BRIDGE_HISTORY_CONFIG_PATH = "./volume/bridge-history-config.yaml";
string constant BALANCE_CHECKER_CONFIG_PATH = "./volume/balance-checker-config.yaml";
string constant FRONTEND_ENV_PATH = "./volume/frontend-config.yaml";
string constant ROLLUP_EXPLORER_BACKEND_CONFIG_PATH = "./volume/rollup-explorer-backend-config.yaml";
string constant ADMIN_SYSTEM_BACKEND_CONFIG_PATH = "./volume/admin-system-backend-config.yaml";

// plonk verifier configs
bytes32 constant V4_VERIFIER_DIGEST = 0x0a1904dbfff4614fb090b4b3864af4874f12680c32f07889e9ede8665097e5ec;

// plonk verifier v0.13.1 creation code
bytes constant PLONK_VERIFIER_CREATION_CODE = hex"62000025565b60006040519050600081036200001a57606090505b818101604052919050565b6136a3620000338162000005565b816200003f82398181f3fe60017f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd477f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001610151565b60007f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd4782107f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47841080821692505050600082146000841480821780158481169450505050507f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd478384097f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd478384097f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd478482097f30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47600382088381148581169550505050505092915050565b8060003506602052806020350660405280604035066060528060603506608052806080350660a0528060a0350660c0528060c0350660e0528060e0350661010052806101003506610120528061012035066101405280610140350661016052806101603506610180528061018035066101a052806101a035066101c052806101c035066101e052806101e0350661020052806102003506610220528061022035066102405280610240350661026052806102603506610280528061028035066102a052806102a035066102c052806102c035066102e052806102e0350661030052806103003506610320527f083d7f8552bdf1dd98458c19d469c458809424d40c483abc2e528b75a6f0f1466000526103203580610340526103403580610360528461027d8284610048565b169450505061038060002061038052610380518181066103a052806103c0525061036035806103e052610380358061040052846102ba8284610048565b169450505060606103c02061042052610420518181066104405280610460525060016104805360216104602061048052610480518181066104a052806104c052506103a035806104e0526103c0358061050052846103188284610048565b16945050506103e03580610520526104003580610540528461033a8284610048565b16945050506104203580610560526104403580610580528461035c8284610048565b169450505060e06104c0206105a0526105a0518181066105c052806105e05250610460358061060052610480358061062052846103998284610048565b16945050506104a03580610640526104c0358061066052846103bb8284610048565b16945050506104e035806106805261050035806106a052846103dd8284610048565b169450505061052035806106c05261054035806106e052846103ff8284610048565b16945050506101206105e0206107005261070051818106610720528061074052508061056035066107605280610580350661078052806105a035066107a052806105c035066107c052806105e035066107e0528061060035066108005280610620350661082052806106403506610840528061066035066108605280610680350661088052806106a035066108a052806106c035066108c052806106e035066108e052806107003506610900528061072035066109205280610740350661094052806107603506610960526102406107402061098052610980518181066109a052806109c0525060016109e05360216109c0206109e0526109e051818106610a005280610a2052506107803580610a40526107a03580610a6052846105248284610048565b16945050506060610a2020610a8052610a8051818106610aa05280610ac052506107c03580610ae0526107e03580610b0052846105618284610048565b169450505060205160405160581b8101905060605160b01b8101905080610b205260805160a05160581b8101905060c05160b01b8101905080610b4052846105a98284610048565b169450505060e0516101005160581b810190506101205160b01b8101905080610b6052610140516101605160581b810190506101805160b01b8101905080610b8052846105f68284610048565b169450505080610720516107205109610ba05280610ba051610ba05109610bc05280610bc051610bc05109610be05280610be051610be05109610c005280610c0051610c005109610c205280610c2051610c205109610c405280610c4051610c405109610c605280610c6051610c605109610c805280610c8051610c805109610ca05280610ca051610ca05109610cc05280610cc051610cc05109610ce05280610ce051610ce05109610d005280610d0051610d005109610d205280610d2051610d205109610d405280610d4051610d405109610d605280610d6051610d605109610d805280610d8051610d805109610da05280610da051610da05109610dc05280610dc051610dc05109610de05280610de051610de05109610e005280610e0051610e005109610e205280610e2051610e205109610e405280610e4051610e405109610e605280610e6051610e605109610e805280610e8051610e805109610ea05280610ea051610ea05109610ec052807f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000610ec05108610ee052807f30644e66c81e03716be83b486d6feabcc7ddd0fe6cbf5e72d585d142f7829b05610ee05109610f0052807f2d19f86a2342079b8c1a6417471d461040256eaa689be51f08e6a92e1243ce65610f005109610f2052807f034a5608bdef988e2c35e19f3a64124ce80e799e111d8b723afb4c65ddbc319c6107205108610f4052807f24a1fcd63e9f03b27281db85fe631ec8e5c466f8178a4ee94d4942b7ccd90e1c610f005109610f6052807f0bc2519ca2929c7745ce6a30831e3994426f8150622f21a7f698b2dc2326f1e56107205108610f8052807f0d5eb4c216db2c3262de3f6a2ef71a9be95ff21a7a1a50ed069d6131e7d54e5f610f005109610fa052807f230599b0ca5673f75572064c528a3dc13ed3f62dff9f1fa43d449462082ab1a26107205108610fc052807f26501ebfe559ea5826f023d3e76e4b66f170cd940408eb5590a4075c80b498d6610f005109610fe052807f0a142fb2fbd7b5d1916021e29a130cf636c31ab475b0853bb33dee376f4b672b610720510861100052807f082a7bd4c0a7e4352229d332c27a160da18f0d7c651f3047df41b80345532f6e610f00510961102052807f2839d29e2089bbf496267283bf07424f86a4dacc149a404964a03d90aaacd093610720510861104052807f19277f31ecb5bfe8604677099c09556812b0b5c50cceb2b584098183a5a6c5c8610f00510961106052807f173ccf40f47be0415809ceace57802f5158332836ceabddbbfd874104a593a39610720510861108052807f20bab6e5f766b4edf82399e9c5ff0e40d4b6875321a3d8020e18521d8f5c7241610f0051096110a052807f0fa9978ce9caeb3bc02cabccbb824a1c537d60f55815988f35c9a37660a38dc061072051086110c052806001610f0051096110e052807f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000610720510861110052807f1dba8b5bdd64ef6ce29a9039aca3c0e524395c43b9227b96c75090cc6cc7ec97610f00510961112052807f12a9c31703ccb0bcd5b5b57cd4dd977803fa8c04c096f4fa7c9164c78338136a610720510861114052807f0d94d63997367c97a8ed16c17adaae39262b9af83acb9e003f94c217303dd160610f00510961116052807f22cf783949fb23920f632ef506a6aa2402084d503eedd291044d337cbfc22ea1610720510861118052807f303a348fae5a4f041e5c056919bc140f68267e2fb55a522282b02d6a100e01a0610f0051096111a052807e2a19e332d7512599f4404d67c5444dc00d6a18c45f1e6ec131c829dff1fe6161072051086111c052807f1951441010b2b95a6e47a6075066a50a036f5ba978c050f2821df86636c0facb610f0051096111e052807f17130a62d07ee6cf4a089faf311ab35324c48c9f00f91f9ec1c3fd2db93f0536610720510861120052807f04fe6e3fa02c3830525c10d7bbf567639bfc836de8fe4e471c889a638d381c71610f00510961122052807f2b65e033410567f965f434dec58bf0f98c3764da90bb224a27595b3062c7e390610720510861124052807f24db2e49a2c215211bae763372d0d8b05d0140adbc6d9d63f2a226fb711fd873610f00510961126052807f0b8920293e6f8b089ca1cf830eb07faccb32a79abd4bd32d513fce987ee0278e610720510861128052807f0f6afbf59e2fef78443acf353ca6d17cfc07ebc6343141cd56a9102bd4864004610f0051096112a052807f20f9527d4301b0b17415768144da86e02c2bfc8245882ec3ed38e5681b79bffd61072051086112c052807f1283ba6f4b7b1a76ba2008fe823128bea4adb9269cbfd7c41c223be65bc60863610f0051096112e052807f1de0940395b685b2fe303cb7ff502f9e83862f21dcf998cd27bfb9ad9439f79e610720510861130052807f10e6c9ec7941500e1b1095e82fb0034bd9e95777ca9ae5ce296eadc089110518610f00510961132052807f1f7d848667f0501b9d3fafce51d155114e4a90d0af1e8ac31a7347d366eefae9610720510861134052807f25ad5db2a6bf79a14fd0d2ffd3d0927af7fdd30bce40f88fb46774fd262d7673610f00510961136052807f0ab6f0c03a722688687f72b6adb0c5e23036153cab7878018f7a8096c9d2898e610720510861138052807f2cd3ee06866876806a4a382f7a95576f34fd9ce6aad8bf350670ed33fe3259ac610f0051096113a052807f0390606c5ac929a94e060d8706ec00edf3364b61cee0b15c3d71085ff1cda65561072051086113c052807f2f835d9f4207df4efa4ffa0b2bbf9a4f54221c57cc506b7a5f8dae90bd2e3d0a610f0051096113e052807ee0f0d39f29c0dabe004bab55c1be0dd411cbf0ad690516e454470332d1c2f7610720510861140052807f30526acf1fa80f36309d80530d854ae7d52fc97bcb8d0a6a2a7f852e7b6e9d79610f00510961142052807e11e3a3c18990f387b2c56373fc0d7553041eccae2c66271962706574916288610720510861144052807f0af04af9c243a8b4b8767330b8dae01f562d7641cdf0a0c4d288e395c0aebb72610f00510961146052807f257403791eedf774ffd9d285c8a6783dd2067206abc8cfcc715911fe2f51448f610720510861148052807f2387d5be5175ba27fd2f8779b460ffdd830e06cd2f6bcf30c3715fbed25b1b67610f0051096114a052807f0cdc78b48fbbe601bb20be3ccd20587fa525e17b4a4da160807095d51da4e49a61072051086114c052807f18c95f1ae6514e11a1b30fd7923947c5ffcec5347f16e91b4dd654168326bede610f0051096114e052807f179aef57fae05218169d35deef48109728652313faa28775f60ba17d6cd94123610720510861150052807f1ed7bccd53b52d451436ae36d9f0225657083d7e909edb5560d7ea488aebe0d1610f00510961152052807f118c91a58d7c72e4a419977fa7913606d12baac9e91a953be30a0b4b65141f30610720510861154052807f0ba3551f265c0941ccb3766d47b26720ad620a597137ff3c84310bd3e28e26c9610f00510961156052807f24c0f953bad596e7eb9ccf4939cef13c7ad1ddef08817154bfb0e9c00d71d938610720510861158052807f0803f4ae22d04b4c9c282c70c843e12bfb2d84b89bd7ef84dc3b90d60053b1c8610f0051096115a052807f286059c4be6154dd1c281945b93d77312d06638fdde1810c67a664bdefac4e3961072051086115c052807f29aa84e8187de51daa6de67f44fe365fbb789d1e5f97bc95844628487ebd3a0d610f0051096115e052807f06b9c98ac8b3bb0c0de25f373c8321fd6cbb4b2a1a21b3fbbf9bcd4b7142c5f4610720510861160052807f0e4fc6c7e1947e44222db52506e305b8a9ad70f6a834db5a4778d4a30f1c6f92610f00510961162052807f221487aaff9d21e5962290917a9e52a47e867751d1849536fc6920f0e0e3906f610720510861164052807f20816bee57855658ecd8a204faf6bced826a725b63c6a1a388b4609a2478809f610f00510961166052807f0fe2e28489ac49d0cb77a3b1868a9b6fa5c975ed15f2ceedbb2d94f9cb877f62610720510861168052807f0d44b8855e09d5ae332469459793c1444814f6d137f9e93e780bd41c97e37caa610f0051096116a052807f231f95ed8327ca7b852bdc70e9ed9718e01ef17741bf8752cbd62177581c835761072051086116c052807f07fe49da5568a43070d955e0d212d956e1ff8abd41a763c737e292bee0476699610f0051096116e052807f286604988bc8fbf94776efd5af6e7f0646345d8b38120cca0bff62d50fb89968610720510861170052610f40518181610f805109905080611720528181610fc051099050806117405281816110005109905080611760528181611040510990508061178052818161108051099050806117a05281816110c051099050806117c052818161110051099050806117e0528181611140510990508061180052818161118051099050806118205281816111c051099050806118405281816112005109905080611860528181611240510990508061188052818161128051099050806118a05281816112c051099050806118c052818161130051099050806118e0528181611340510990508061190052818161138051099050806119205281816113c051099050806119405281816114005109905080611960528181611440510990508061198052818161148051099050806119a05281816114c051099050806119c052818161150051099050806119e05281816115405109905080611a005281816115805109905080611a205281816115c05109905080611a405281816116005109905080611a605281816116405109905080611a805281816116805109905080611aa05281816116c05109905080611ac05281816117005109905080611ae0528181610ee05109905080611b0052506020611b40526020611b60526020611b8052611b0051611ba0527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffffff611bc0527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001611be0528260016020611b2060c0611b4060055afa14169250611b20516000610ee05190508282611ae05109610ee0528282820991506117005190508282611ac05109611700528282820991506116c05190508282611aa051096116c0528282820991506116805190508282611a805109611680528282820991506116405190508282611a605109611640528282820991506116005190508282611a405109611600528282820991506115c05190508282611a2051096115c0528282820991506115805190508282611a0051096115805282828209915061154051905082826119e051096115405282828209915061150051905082826119c05109611500528282820991506114c051905082826119a051096114c0528282820991506114805190508282611980510961148052828282099150611440519050828261196051096114405282828209915061140051905082826119405109611400528282820991506113c0519050828261192051096113c052828282099150611380519050828261190051096113805282828209915061134051905082826118e051096113405282828209915061130051905082826118c05109611300528282820991506112c051905082826118a051096112c0528282820991506112805190508282611880510961128052828282099150611240519050828261186051096112405282828209915061120051905082826118405109611200528282820991506111c0519050828261182051096111c052828282099150611180519050828261180051096111805282828209915061114051905082826117e051096111405282828209915061110051905082826117c05109611100528282820991506110c051905082826117a051096110c052828282099150611080519050828261178051096110805282828209915061104051905082826117605109611040528282820991506110005190508282611740510961100052828282099150610fc051905082826117205109610fc052828282099150610f805190508282610f405109610f805282828209915081610f4052505080610f4051610f205109611c005280610f8051610f605109611c205280610fc051610fa05109611c40528061100051610fe05109611c605280611040516110205109611c805280611080516110605109611ca052806110c0516110a05109611cc05280611100516110e05109611ce05280611140516111205109611d005280611180516111605109611d2052806111c0516111a05109611d405280611200516111e05109611d605280611240516112205109611d805280611280516112605109611da052806112c0516112a05109611dc05280611300516112e05109611de05280611340516113205109611e005280611380516113605109611e2052806113c0516113a05109611e405280611400516113e05109611e605280611440516114205109611e805280611480516114605109611ea052806114c0516114a05109611ec05280611500516114e05109611ee05280611540516115205109611f005280611580516115605109611f2052806115c0516115a05109611f405280611600516115e05109611f605280611640516116205109611f805280611680516116605109611fa052806116c0516116a05109611fc05280611700516116e05109611fe05280602051611ce05109818183604051611d005109089050818183606051611d205109089050818183608051611d40510908905081818360a051611d60510908905081818360c051611d80510908905081818360e051611da0510908905081818361010051611dc0510908905081818361012051611de0510908905081818361014051611e00510908905081818361016051611e20510908905081818361018051611e4051090890508181836101a051611e6051090890508181836101c051611e8051090890508181836101e051611ea0510908905081818361020051611ec0510908905081818361022051611ee0510908905081818361024051611f00510908905081818361026051611f20510908905081818361028051611f4051090890508181836102a051611f6051090890508181836102c051611f8051090890508181836102e051611fa0510908905081818361030051611fc0510908905081818361032051611fe0510908905080612000525080610780516107a05109612020528061202051610760510861204052806107c0518203612040510861206052806108205161206051096120805280612080516105c051096120a052806108e05182036001086120c05280611ce0516120c051096120e052806120e0516120a051086121005280612100516105c0510961212052806108e0516108e0510961214052806108e051820361214051086121605280611c0051612160510961218052806121805161212051086121a052806121a0516105c051096121c05280611c005182036001086121e05280611c4051611c2051086122005280611c605161220051086122205280611c805161222051086122405280611ca05161224051086122605280611cc051612260510861228052806122805182036121e051086122a052806104405161088051096122c052806122c0516107e051086122e052806104a0516122e051086123005280610440516108a05109612320528061232051610760510861234052806104a051612340510861236052806123005161236051096123805280610440516108c051096123a052806123a05161200051086123c052806104a0516123c051086123e05280612380516123e05109612400528061090051612400510961242052806104405160010961244052806124405161072051096124605280612460516107e0510861248052806104a05161248051086124a05280610440517f09226b6e22c6f0ca64ec26aad4c86e715b5f898e5e963f25870e56bbe533e9a2096124c052806124c05161072051096124e052806124e051610760510861250052806104a051612500510861252052806124a05161252051096125405280610440517f13b360d4e82fe915fed16081038f98c211427b87a281bd733c277dbadf10372b09612560528061256051610720510961258052806125805161200051086125a052806104a0516125a051086125c05280612540516125c051096125e052806108e0516125e051096126005280612600518203612420510861262052806122a05161262051096126405280612640516121c051086126605280612660516105c051096126805280611ce05161092051096126a052806126a05161268051086126c052806126c0516105c051096126e05280611c005161092051096127005280612700516126e051086127205280612720516105c051096127405280610440516108005108612760528061084051610760510961278052806104405161278051086127a05280612760516127a051096127c0528061092051820361094051086127e052806127c0516127e051096128005280610960516127a05109612820528061282051820361276051086128405280612840518203612800510861286052806122a051612860510961288052806128805161274051086128a05280610ec051610ec051096128c05280610ec0516128c051096128e05280610ec0516128e051096129005280610ec05160010961292052806128c05160010961294052806128e0516001096129605280610ee0516128a05109612980528061072051610ba051096129a05280600161072051096129c052806129c0518203610aa051086129e052807f0d94d63997367c97a8ed16c17adaae39262b9af83acb9e003f94c217303dd1606107205109612a005280612a00518203610aa05108612a2052807f1dba8b5bdd64ef6ce29a9039aca3c0e524395c43b9227b96c75090cc6cc7ec976107205109612a405280612a40518203610aa05108612a6052807f303a348fae5a4f041e5c056919bc140f68267e2fb55a522282b02d6a100e01a06107205109612a805280612a80518203610aa05108612aa052807f2eedbf565be4b0b88a0e251d750f7559486d77bea4d5c9612ce3041295d380d5610aa051098181837f01768f1c854cef712e4220990c71e303dfc67089d4e3a73016fef1815a2c7f2c610720510908905080612ac05250807f0cf547ca658485dd9a20bd27b080d3147ec1caa826e725f7f7989fc9668dd16f610aa051098181837f077ebe9a531776ef7c9e90d5a0685181f70e74298eca38a6c92d84d4c0457ceb610720510908905080612ae05250807f077ebe9a531776ef7c9e90d5a0685181f70e74298eca38a6c92d84d4c0457ceb610aa051098181837e32f4eea6716d08d38119c3d378a36e865ffacfa73eb2357603f3f3368c88c6610720510908905080612b005250807f0d71dfba734c88cf774db4e0e4f959cb98acfbbb1fc789e5167bbca1fcafd24e610aa051098181837f25ea65fea4371c04dd1eaf23d69f2e0f9524ef5b9845d01cdb218e89a8052321610720510908905080612b205250806129e051600109612b405280612a6051612b405109612b605280612a2051612b605109612b805280612aa051612b805109612ba052807f12a9c31703ccb0bcd5b5b57cd4dd977803fa8c04c096f4fa7c9164c78338136b610aa051098181837f1dba8b5bdd64ef6ce29a9039aca3c0e524395c43b9227b96c75090cc6cc7ec96610720510908905080612bc05250807f1dba8b5bdd64ef6ce29a9039aca3c0e524395c43b9227b96c75090cc6cc7ec96610aa051098181837f1025b522462e72d539ad797831c912abfe0dc14b7e56dd9687bbceb53c8a1b37610720510908905080612be05250806001610aa051098181837f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000000610720510908905080612c005250612ac0518181612ae05109905080612c20528181612b005109905080612c40528181612b205109905080612c60528181612bc05109905080612c80528181612be05109905080612ca0528181612b605109905080612cc0528181612c005109905080612ce0528181612b405109905080612d0052506020612d40526020612d60526020612d8052612d0051612da0527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffffff612dc0527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001612de0528260016020612d2060c0612d4060055afa14169250612d20516000612b405190508282612ce05109612b4052828282099150612c005190508282612cc05109612c0052828282099150612b605190508282612ca05109612b6052828282099150612be05190508282612c805109612be052828282099150612bc05190508282612c605109612bc052828282099150612b205190508282612c405109612b2052828282099150612b005190508282612c205109612b0052828282099150612ae05190508282612ac05109612ae05282828209915081612ac0525050612ac0518181612ae0510890508181612b00510890508181612b205108905080612e00525080612b6051612ba05109612e2052612bc0518181612be05108905080612e40525080612b4051612ba05109612e6052612c005180612e805250612e00518181612e405109905080612ea0528181612e805109905080612ec052506020612f00526020612f20526020612f4052612ec051612f60527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffffff612f80527f30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001612fa0528260016020612ee060c0612f0060055afa14169250612ee0516000612e805190508282612ea05109612e8052828282099150612e405190508282612e005109612e405282828209915081612e0052505080612e4051612e205109612fc05280612e8051612e605109612fe052806109a0516109a0510961300052806109a051613000510961302052806109a051613020510961304052806109a051613040510961306052806109a051613060510961308052806109a05161308051096130a052806109a0516130a051096130c052806109a0516130c051096130e052806109a0516130e051096131005280610a0051610a0051096131205280610a005161312051096131405280612ac0516107605109818183612ae0516107805109089050818183612b00516107a05109089050818183612b20516107c0510908905080613160525080612e0051613160510961318052806001613180518303096131a0528060016131a051096131c05280612e20516001096131e05280612bc0516108e05109818183612be051610900510908905080613200525080612fc05161320051096132205280600161322051830309613240528060016131e051096132605280612bc0516109205109818183612be051610940510908905080613280525080612fc05161328051096132a052806109a0516132a0518303096132c052806109a0516131e051096132e052806132c05161324051086133005280610a005161330051096133205280610a005161326051096133405280610a00516132e051096133605280613320516131c051086133805280612e60516001096133a05280612c00516109605109806133c0525080612fe0516133c051096133e0528060016133e051830309613400528060016133a051096134205280612c00516107e0510980613440525080612fe051613440510961346052806109a0516134605183030961348052806109a0516133a051096134a052806134805161340051086134c05280612c00516108005109806134e0525080612fe0516134e05109613500528061300051613500518303096135205280613000516133a051096135405280613520516134c051086135605280612c0051610820510980613580525080612fe05161358051096135a05280613020516135a0518303096135c05280613020516133a051096135e052806135c05161356051086136005280612c0051610840510980613620525080612fe0516136205109613640528061304051613640518303096136605280613040516133a0510961368052806136605161360051086136a05280612c00516108805109806136c0525080612fe0516136c051096136e05280613060516136e0518303096137005280613060516133a051096137205280613700516136a051086137405280612c00516108a0510980613760525080612fe0516137605109613780528061308051613780518303096137a05280613080516133a051096137c052806137a05161374051086137e05280612c00516108c0510980613800525080612fe051613800510961382052806130a0516138205183030961384052806130a0516133a051096138605280613840516137e051086138805280612e605161292051096138a05280612e605161294051096138c05280612e605161296051096138e05280612c0051612980510980613900525080612fe051613900510961392052806130c0516139205183030961394052806130c0516133a0510961396052806130c0516138a0510961398052806130c0516138c051096139a052806130c0516138e051096139c052806139405161388051086139e05280612c0051610860510980613a00525080612fe051613a005109613a2052806130e051613a2051830309613a4052806130e0516133a05109613a605280613a40516139e05108613a80528061312051613a805109613aa05280613120516134205109613ac05280613120516134a05109613ae05280613120516135405109613b005280613120516135e05109613b205280613120516136805109613b405280613120516137205109613b605280613120516137c05109613b805280613120516138605109613ba05280613120516139605109613bc05280613120516139805109613be05280613120516139a05109613c005280613120516139c05109613c20528061312051613a605109613c405280613aa0516133805108613c605280612ba051600109613c805280610aa051600109613ca0526001613cc0526002613ce052613c6051613d00528260016040613cc06060613cc060075afa14169250613cc051613d2052613ce051613d405261034051613d605261036051613d80528260016040613d206080613d2060065afa141692506104e051613da05261050051613dc05261334051613de0528260016040613da06060613da060075afa14169250613d2051613e0052613d4051613e2052613da051613e4052613dc051613e60528260016040613e006080613e0060065afa1416925061052051613e805261054051613ea05261336051613ec0528260016040613e806060613e8060075afa14169250613e0051613ee052613e2051613f0052613e8051613f2052613ea051613f40528260016040613ee06080613ee060065afa141692506103e051613f605261040051613f8052613ac051613fa0528260016040613f606060613f6060075afa14169250613ee051613fc052613f0051613fe052613f605161400052613f8051614020528260016040613fc06080613fc060065afa141692507f2ad47afc517e78898ecd3a5c20c46975e6c50bf030951071878c7470e2f3f9f1614040527f1ceaca4426cdc11c593eee4db1e3981bfd8bd0eba770b93aa85f5f15dc16096061406052613ae051614080528260016040614040606061404060075afa14169250613fc0516140a052613fe0516140c052614040516140e052614060516141005282600160406140a060806140a060065afa141692507f0fb05ccb81603592ce60bd6199890470ef6f9caca3c17570df7701d70a2dd957614120527f1cc1301d6d462edf2e79083532a337ef3f087fbf0b9516d08074784017e10c7e61414052613b0051614160528260016040614120606061412060075afa141692506140a051614180526140c0516141a052614120516141c052614140516141e0528260016040614180608061418060065afa141692507f1e69edc3b54a25a5be1efb7515b5eaa259569e44cf6e7b99887bd2015311104f614200527f293e037f34e8ad87a6ebea272575c751f96a1e0acbf05bf5774e0581c3cc382361422052613b2051614240528260016040614200606061420060075afa1416925061418051614260526141a05161428052614200516142a052614220516142c0528260016040614260608061426060065afa141692507f0cf666852fd76b36f03572da1111ea68014217801887369fd35f9460f6bb13246142e0527f230bb407465f3dcda6711ec136903711485b30046005c0dd769bd85d1cc8a56761430052613b40516143205282600160406142e060606142e060075afa14169250614260516143405261428051614360526142e05161438052614300516143a0528260016040614340608061434060065afa141692507f2c2ef5dd4ea527c7b6a1adb979cf19e316cf50515b2225ecd040f40f46ad8fc66143c0527f2cd240820bffbbfa44c0832dfe16e8a40c4e75d800f58f7576733ca37a9c73696143e052613b60516144005282600160406143c060606143c060075afa14169250614340516144205261436051614440526143c051614460526143e051614480528260016040614420608061442060065afa141692507f1e2415bae32b721ff7b95b1766a3d0a4ea86d62fc8b4ed864092e8be29b375b46144a0527f0193d85fa914927d0567822f343ead8682e19e1948bdfe0d70e5ce64eaddf26a6144c052613b80516144e05282600160406144a060606144a060075afa14169250614420516145005261444051614520526144a051614540526144c051614560528260016040614500608061450060065afa141692507f02b01e53fe9c70fbc4e13606ffb809f58993a5b31d9e9a69e5c86b2833b52ac8614580527f21fe9d89f5e7d29aa77fb345a045fabbcc5f2be8bbd2f571306475118175ae306145a052613ba0516145c0528260016040614580606061458060075afa14169250614500516145e052614520516146005261458051614620526145a0516146405282600160406145e060806145e060065afa1416925061060051614660526106205161468052613bc0516146a0528260016040614660606061466060075afa141692506145e0516146c052614600516146e0526146605161470052614680516147205282600160406146c060806146c060065afa1416925061064051614740526106605161476052613be051614780528260016040614740606061474060075afa141692506146c0516147a0526146e0516147c052614740516147e052614760516148005282600160406147a060806147a060065afa1416925061068051614820526106a05161484052613c0051614860528260016040614820606061482060075afa141692506147a051614880526147c0516148a052614820516148c052614840516148e0528260016040614880608061488060065afa141692506106c051614900526106e05161492052613c2051614940528260016040614900606061490060075afa1416925061488051614960526148a05161498052614900516149a052614920516149c0528260016040614960608061496060065afa14169250610560516149e05261058051614a0052613c4051614a205282600160406149e060606149e060075afa1416925061496051614a405261498051614a60526149e051614a8052614a0051614aa0528260016040614a406080614a4060065afa14169250610a4051614ac052610a6051614ae052613c80518103614b00528260016040614ac06060614ac060075afa14169250614a4051614b2052614a6051614b4052614ac051614b6052614ae051614b80528260016040614b206080614b2060065afa14169250610ae051614ba052610b0051614bc052613ca051614be0528260016040614ba06060614ba060075afa14169250614b2051614c0052614b4051614c2052614ba051614c4052614bc051614c60528260016040614c006080614c0060065afa14169250614c0051614c8052614c2051614ca052610ae051614cc052610b0051614ce052610b2051614d0052610b4051614d2052610b6051614d4052610b8051614d6052610100614c8020614d805280614d805106614da05280614da051614da05109614dc05280614da051600109614de052614d0051614e0052614d2051614e2052614de051614e40528260016040614e006060614e0060075afa14169250614c8051614e6052614ca051614e8052614e0051614ea052614e2051614ec0528260016040614e606080614e6060065afa14169250614d4051614ee052614d6051614f0052614de051614f20528260016040614ee06060614ee060075afa14169250614cc051614f4052614ce051614f6052614ee051614f8052614f0051614fa0528260016040614f406080614f4060065afa14169250614e6051614fc052614e8051614fe0527f198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2615000527f1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed615020527f090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b615040527f12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa61506052614f405161508052614f60516150a0527f186282957db913abd99f91db59fe69922e95040603ef44c0bd7aa3adeef8f5ac6150c0527f17944351223333f260ddc3b4af45191b856689eda9eab5cbcddbbe570ce860d26150e0527f06d971ff4a7467c3ec596ed6efc674572e32fd6f52b721f97e35b0b3d3546753615100527f06ecdb9f9567f59ed2eee36e1e1d58797fd13cc97fafc2910f5e8a12f202fa9a615120528260016020614fc0610180614fc060085afa14169250826001614fc051141692508261369e57600080fd5b600080f3";
