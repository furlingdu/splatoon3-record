import type { ReactElement } from 'react';

const zncaApiUrl = 'https://github.com/samuelthomas2774/nxapi-znca-api';

function nsoApiNotice(): ReactElement {
  return (
    <div className="bind-info">
      为获取到您的Nintendo Switch Online数据，程序将要求登录您的Nintendo账户。由于Nintendo限制，在登录过程中会涉及到使用第三方Nintendo Switch Online Api以实现加密包体获取，你的 Nintendo 账号 id_token 将被发送到第三方 API（
      <a className="notice-link" href={zncaApiUrl}
        onClick={(event) => { event.preventDefault(); void window.recordApi.openLink(zncaApiUrl); }}>nxapi-znca-api</a>
      ）用于完成令牌校验。
      <br />
      请注意，由于涉及到了第三方Api进行操作，该操作可能存在部分风险或稳定性较差，开发者不对账户安全性进行保证。但请放心，id_token并不会泄露您的账户。您的Nintendo Switch Online账户数据将会被加密保存至本地。
    </div>
  );
}

export { nsoApiNotice as NsoApiNotice };
