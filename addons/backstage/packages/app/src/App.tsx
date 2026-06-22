import { createApp } from '@backstage/frontend-defaults';
import catalogPlugin from '@backstage/plugin-catalog/alpha';
import notificationsPlugin from '@backstage/plugin-notifications/alpha';
import scaffolderPlugin from '@backstage/plugin-scaffolder/alpha';
import toolhivePlugin from '@internal/plugin-toolhive';
import { navModule } from './modules/nav';

export default createApp({
  features: [catalogPlugin, notificationsPlugin, scaffolderPlugin, toolhivePlugin, navModule],
});
